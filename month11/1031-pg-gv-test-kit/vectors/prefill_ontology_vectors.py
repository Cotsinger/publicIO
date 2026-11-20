#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补填本体三表的 bge-m3 向量（search_vector_m3），PG / GaussVector 通用。

替代同目录下的 prefill_ontology_search_text.py（已删除）：
旧脚本以 search_vector(768) 判空，m3 为空但 768 已填时整行被跳过；
且依赖 LLM Key 与本地 sentence-transformers，在“只注册了本体元数据、
检索文本列已由数据库生成列维护”的库上补不了 m3。本脚本只补数据、
不改代码，直接用库内已有的 search_text_bm25 作为嵌入文本。

背景：通过原生 SQL 注册本体时会绕过 OSI 导入链路上的向量刷新，
导致 t_semantic_ontology_definition / t_semantic_entity_type /
t_semantic_relation_type 的 search_vector_m3 为空（PG）或全零（GV），
本体检索的向量波次只能靠精确/BM25 命中。

本脚本做五件事：
  1. 按后端识别“未填充”行：
     - PostgreSQL : search_vector_m3 IS NULL 或 L2 范数为 0；
     - GaussVector: floatvector 列 NOT NULL + DEFAULT 全零，只判 L2 范数为 0；
  2. 处理检索文本 search_text_bm25：
     - PG/GV 上是 GENERATED ALWAYS AS (api_name/display_name/description) 存储生成列，
       数据库自动维护，脚本只读、绝不写；
     - DWS 等不支持生成列的普通 TEXT：只在文本为空时按同一表达式补齐，
       已有内容不覆盖，补完再用新文本算向量；
  3. 取检索文本作为嵌入输入，调 OpenAI 兼容嵌入服务算 1024 维向量；
  4. 生成 UPDATE（事务内执行，只填空值，可重复执行）；
  5. 执行后复核待填数，并输出 JSON 汇总。

使用方法见同目录 README.md。
依赖：本机可执行 docker exec；嵌入服务为 OpenAI 兼容 /v1/embeddings。

注意：--db 无默认值，必须显式指定，避免误写同容器内的其他实例库。
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import urllib.request

TABLES = [
    "t_semantic_ontology_definition",
    "t_semantic_entity_type",
    "t_semantic_relation_type",
]
ZERO_EPS = 1e-6

# 检索文本列：PG/GV 为 GENERATED ALWAYS AS (…) STORED，由数据库维护；
# DWS 等不支持生成列的后端为普通 TEXT，需要脚本按同一表达式补齐。
TEXT_COLUMN = "search_text_bm25"
TEXT_EXPR = (
    "coalesce(api_name, '') || ' ' || coalesce(display_name, '') || ' ' || "
    "coalesce(description, '')"
)


def run_sql(args: argparse.Namespace, sql: str) -> str:
    """在容器内执行 SQL；SQL 走 stdin，避免 shell 引号问题。"""
    cmd = ["docker", "exec", "-i"]
    if args.container_user:
        cmd += ["-u", args.container_user]
    if args.backend != "gaussvector" and args.db_password:
        cmd += ["-e", f"PGPASSWORD={args.db_password}"]

    if args.backend == "gaussvector":
        auth = f" -W {shlex.quote(args.db_password)}" if args.db_password else ""
        inner = (
            f"export LD_LIBRARY_PATH={shlex.quote(args.gv_lib_path)}:${{LD_LIBRARY_PATH:-}}; "
            f"exec {shlex.quote(args.gsql)}"
            f" -U {shlex.quote(args.db_user)} -p {args.db_port} -d {shlex.quote(args.db)}"
            f"{auth}"
            " -A -t -v ON_ERROR_STOP=1"
        )
        cmd += [args.container, "bash", "-lc", inner]
    else:
        cmd += [
            args.container, "psql",
            "-U", args.db_user, "-p", str(args.db_port), "-d", args.db,
            "-A", "-t", "-v", "ON_ERROR_STOP=1",
        ]

    proc = subprocess.run(cmd, input=sql, capture_output=True, text=True, encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"SQL failed: {proc.stderr.strip()[:800]}")
    return proc.stdout


def pending_where(backend: str) -> str:
    if backend == "gaussvector":
        return f"coalesce(vector_norm(search_vector_m3), 0) < {ZERO_EPS}"
    return (
        "(search_vector_m3 is null "
        f"or coalesce(vector_norm(search_vector_m3), 0) < {ZERO_EPS})"
    )


def vector_literal(vec: list[float], backend: str) -> str:
    cast = "::floatvector" if backend == "gaussvector" else "::vector"
    return "'[" + ",".join(f"{x:.8f}" for x in vec) + "]'" + cast


def embed(args: argparse.Namespace, texts: list[str]) -> list[list[float]]:
    body = json.dumps({"model": args.embed_model, "input": texts}).encode("utf-8")
    req = urllib.request.Request(
        args.embed_url, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=args.embed_timeout) as resp:
        doc = json.load(resp)
    vectors = [item["embedding"] for item in doc.get("data", [])]
    if len(vectors) != len(texts):
        raise RuntimeError(f"embedding count mismatch: {len(vectors)} != {len(texts)}")
    bad = [len(v) for v in vectors if len(v) != args.dims]
    if bad:
        raise RuntimeError(f"embedding dims {bad[0]} != expected {args.dims}; refuse to write")
    return vectors


def quote_id(value: str) -> str:
    return value.replace("'", "''")


def text_column_generated(args: argparse.Namespace, table: str) -> bool:
    """判断 search_text_bm25 是否为生成列（PG/GV 为 ALWAYS，DWS 为 NEVER）。"""
    sql = (
        "select is_generated from information_schema.columns "
        f"where table_schema = current_schema() and table_name = '{table}' "
        f"and column_name = '{TEXT_COLUMN}';"
    )
    values = [ln.strip() for ln in run_sql(args, sql).splitlines() if ln.strip()]
    if not values:
        raise RuntimeError(f"{table}.{TEXT_COLUMN} 不存在，请检查 --db / --tables")
    return values[-1].upper() == "ALWAYS"


def fetch_pending(
    args: argparse.Namespace, table: str, fill_text: bool
) -> tuple[list[tuple[str, str, bool]], int]:
    """返回 (id, 嵌入文本, 是否需要写文本) 列表，以及无法补文本的待填行数。

    fill_text=True（文本列是普通列）：文本为空的行也要处理，用与生成列
    完全相同的表达式补文本，再按新文本算向量；已有文本的行不覆盖文本。
    fill_text=False（文本列是生成列）：只处理 m3 待填且文本非空的行。
    """
    where = pending_where(args.backend)
    blank_text = f"coalesce(btrim({TEXT_COLUMN}), '') = ''"
    if fill_text:
        cond = f"(({where}) or {blank_text})"
        sql = (
            f"select id::text || chr(1) || coalesce({TEXT_COLUMN}, '') || chr(1) || "
            f"({TEXT_EXPR}) from {table} where {cond} order by id;"
        )
    else:
        cond = f"({where}) and not ({blank_text})"
        sql = f"select id::text || chr(1) || {TEXT_COLUMN} from {table} where {cond} order by id;"

    rows: list[tuple[str, str, bool]] = []
    for line in run_sql(args, sql).splitlines():
        if "\x01" not in line:
            continue
        parts = line.split("\x01")
        rid = parts[0].strip()
        if not rid:
            continue
        stored = (parts[1] if len(parts) > 1 else "").strip()
        if fill_text:
            derived = (parts[2] if len(parts) > 2 else "").strip()
            text = stored or derived
            write_text = not stored and bool(derived)
        else:
            text = stored
            write_text = False
        if not text:
            continue
        rows.append((rid, text, write_text))

    empty_sql = (
        f"select count(*) from {table} where ({where}) and {blank_text} "
        f"and coalesce(btrim({TEXT_EXPR}), '') = '';"
    )
    empty = int((run_sql(args, empty_sql).strip() or "0").splitlines()[-1])
    return rows, empty


def main() -> int:
    ap = argparse.ArgumentParser(
        description="补填本体三表 search_vector_m3（PG / GaussVector）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "未填充判定：PG = m3 IS NULL 或 L2=0；GV = L2=0（列 NOT NULL + 全零默认）。\n"
            "文本列：PG/GV 为生成列（数据库自动维护，脚本只读）；DWS 等普通列由脚本\n"
            "按同一表达式补齐，且只在文本为空时写入，不覆盖已有内容。"
        ),
    )
    ap.add_argument("--apply", action="store_true", help="写库")
    ap.add_argument("--dry-run", action="store_true", help="只统计，不嵌入、不写库")
    ap.add_argument("--backend", choices=["postgres", "gaussvector"], default="postgres")
    ap.add_argument("--container", required=True, help="目标数据库的 Docker 容器名")
    ap.add_argument("--container-user", help="按指定的容器操作系统用户运行数据库客户端")
    ap.add_argument("--db", required=True, help="目标库名（必填，避免误写其他实例库）")
    ap.add_argument("--db-user", required=True)
    ap.add_argument("--db-password", default="")
    ap.add_argument("--db-port", type=int, default=None,
                    help="容器内端口（PG 默认 5432，GV 默认 5678）")
    ap.add_argument("--gsql", default="/gv/extracted/bin/gsql")
    ap.add_argument("--gv-lib-path", default="/gv/extracted/lib")
    ap.add_argument("--tables", default=",".join(TABLES),
                    help="逗号分隔的表名，默认本体三表")
    ap.add_argument("--text", choices=["auto", "on", "off"], default="auto",
                    help="检索文本列处理：auto=非生成列才补（默认）；"
                         "on=强制补（生成列会报错）；off=只补向量、不碰文本")
    ap.add_argument("--embed-url", default="http://127.0.0.1:8082/v1/embeddings")
    ap.add_argument("--embed-model", default="BAAI/bge-m3")
    ap.add_argument("--embed-timeout", type=int, default=300)
    ap.add_argument("--dims", type=int, default=1024)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--out", default="/tmp/fill-ontology-vectors.sql")
    args = ap.parse_args()

    if args.apply == args.dry_run:
        ap.error("choose exactly one of --apply / --dry-run")
    if args.db_port is None:
        args.db_port = 5678 if args.backend == "gaussvector" else 5432

    tables = [t.strip() for t in args.tables.split(",") if t.strip()]
    for table in tables:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", table):
            ap.error(f"invalid table name: {table}")

    total_pending = 0
    plan: dict[str, list[tuple[str, str]]] = {}
    report = []

    for table in tables:
        generated = text_column_generated(args, table) if args.text != "off" else None
        if args.text == "on" and generated:
            ap.error(f"{table}.{TEXT_COLUMN} 是生成列，由数据库自动维护，不能用 --text on")
        fill_text = args.text == "on" or (args.text == "auto" and generated is False)
        rows, empty = fetch_pending(args, table, fill_text)
        text_writes = sum(1 for _, _, need in rows if need)
        total_pending += len(rows)
        plan[table] = rows
        report.append({
            "table": table,
            "pending": len(rows),
            "text_generated": generated,
            "text_to_write": text_writes,
            "text_empty_unfixable": empty,
        })
        line = (
            f"pending={len(rows)} text_generated={generated} "
            f"text_to_write={text_writes} empty_text={empty}"
        )
        if args.dry_run:
            sample = rows[0][1][:60] if rows else ""
            print(f"[check] {table}: {line} sample={sample!r}")
        else:
            print(f"[read ] {table}: {line}")

    if args.dry_run:
        print("dry-run: no embedding, no write")
        print("report=" + json.dumps(report, ensure_ascii=False))
        return 0

    if total_pending == 0:
        print("nothing to fill")
        print("report=" + json.dumps(report, ensure_ascii=False))
        return 0

    statements: list[str] = []
    for table, rows in plan.items():
        if not rows:
            continue
        ids = [rid for rid, _, _ in rows]
        texts = [text for _, text, _ in rows]
        need_text = [need for _, _, need in rows]
        vectors: list[list[float]] = []
        for start in range(0, len(texts), args.batch_size):
            vectors.extend(embed(args, texts[start:start + args.batch_size]))
        for rid, vec, write_text in zip(ids, vectors, need_text):
            literal = vector_literal(vec, args.backend)
            if write_text:
                statements.append(
                    f"update {table} set {TEXT_COLUMN} = {TEXT_EXPR}, "
                    f"search_vector_m3 = {literal} where id = '{quote_id(rid)}';"
                )
            else:
                statements.append(
                    f"update {table} set search_vector_m3 = {literal} "
                    f"where id = '{quote_id(rid)}';"
                )
        print(
            f"[embed] {table}: {len(rows)} rows, text_writes={sum(need_text)}, "
            f"dims={args.dims}"
        )

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("begin;\n" + "\n".join(statements) + "\ncommit;\n")
    print(f"sql written: {args.out} ({len(statements)} updates)")

    with open(args.out, "rb") as f:
        sql = f.read().decode("utf-8")
    run_sql(args, sql)

    for item in report:
        if item["pending"] == 0:
            continue
        table = item["table"]
        left = int(run_sql(
            args,
            f"select count(*) from {table} where ({pending_where(args.backend)}) "
            f"and coalesce(btrim({TEXT_COLUMN}), '') <> '';",
        ).strip().splitlines()[-1])
        left_text = int(run_sql(
            args,
            f"select count(*) from {table} where coalesce(btrim({TEXT_COLUMN}), '') = '' "
            f"and coalesce(btrim({TEXT_EXPR}), '') = '';",
        ).strip().splitlines()[-1])
        print(
            f"[verify] {table}: remaining pending = {left}, "
            f"blank_text_unfixable = {left_text}"
        )
        item["remaining"] = left
        item["blank_text_unfixable"] = left_text

    print("report=" + json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError) as exc:
        print(f"[error] {exc}", file=sys.stderr)
        raise SystemExit(2)
