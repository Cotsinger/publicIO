# 1031 本体和语义目录向量回填

导入数据和本体后，在每套隔离的测试实例上完成以下两项，再执行检索用例。需要 Python 3、`curl`、数据库客户端和 OpenAI 兼容的 `/v1/embeddings`。1031 使用 `BAAI/bge-m3`（1024 维），测试服务的检索配置和回填工具应使用同一模型。下列命令从本目录在 Bash 中执行。

1031 配置使用 `semantic_service.vector.embedding.service.enable=true`、`semantic_service.vector.embedding.bge_base.enable=false` 和 `semantic_service.vector.embedding.m3.provider=openai`。服务的 `semantic_service.vector.embedding.m3.openai.base-url` 填到 `/v1`，`semantic_service.vector.embedding.m3.openai.model` 填 `BAAI/bge-m3`。下方脚本的 `EMBED_URL` 填完整 `/v1/embeddings` 地址。

## 1. 本体三表回填

运行机器应能执行 `docker exec`，并能访问无鉴权的嵌入地址。PG 容器内使用 `psql`，GV 容器内使用 `gsql`。下列变量填写测试实例的实值，端口用**数据库容器内端口**。数据库认证由测试环境配置，如需密码，可通过 `--db-password "$TEST_DB_PASSWORD"` 传入。脚本按当前 schema 读取三张定义表，1031 使用 `public`。GV 的只读核验也使用数据库准备步骤中的 `GV_GAUSSHOME`。

```bash
pg_options=(
  --backend postgres
  --container "${PG_CONTAINER:?填写 PG 容器名}"
  --db "${PG_DB:?填写 PG 测试库名}"
  --db-user "${PG_DB_USER:?填写 PG 测试账号}"
  --db-port "${PG_DB_PORT:?填写 PG 容器内端口}"
  --embed-url "${EMBED_URL:?填写完整的 /v1/embeddings 地址}"
)
gv_options=(
  --backend gaussvector
  --container "${GV_CONTAINER:?填写 GV 容器名}"
  --container-user "${GV_OS_USER:?填写 GV 容器内客户端运行角色}"
  --db "${GV_DB:?填写 GV 测试库名}"
  --db-user "${GV_DB_USER:?填写 GV 测试账号}"
  --db-port "${GV_DB_PORT:?填写 GV 容器内端口}"
  --gsql "${GV_GSQL:?填写容器内 gsql 路径}"
  --gv-lib-path "${GV_LIB_PATH:?填写容器内 GV 库文件目录}"
  --embed-url "${EMBED_URL:?填写完整的 /v1/embeddings 地址}"
)

python3 prefill_ontology_vectors.py --dry-run "${pg_options[@]}"
python3 prefill_ontology_vectors.py --dry-run "${gv_options[@]}"

python3 prefill_ontology_vectors.py --apply "${pg_options[@]}" --out "$PWD/pg-ontology-fill.generated.sql"
python3 prefill_ontology_vectors.py --apply "${gv_options[@]}" --out "$PWD/gv-ontology-fill.generated.sql"
```

单后端测试只设置对应的参数数组和执行对应命令。`--dry-run` 查询三表待填数量。`--apply` 用 `search_text_bm25` 生成缺失向量，并检查返回是否为 1024 维。1031 的 PG/GV 均由数据库自动生成检索文本列，回填后应看到 `remaining pending = 0` 和 `blank_text_unfixable = 0`。如果导入的快照已带有效向量，待填数可以从 0 开始。

## 2. 语义目录向量回填

确认服务已启动并连接到相应测试库。把服务根地址（如 `http://<测试主机>:<服务端口>`）赋给 `SEMANTIC_BASE_URL`，在每个后端提交一次历史实测使用的请求。请求中的 `upsert=true` 会全量重建当前测试库的 m3 语义目录向量，用于覆盖导入时的全零值；可先跑第 3 步确认该库是否需要全量回填。

```bash
fill_url="${SEMANTIC_BASE_URL:?填写测试服务根地址}"
fill_url="${fill_url%/}/api/semantic/v1/osi/fill-vectors"
auth=()
if [[ -n "${SEMANTIC_TEST_AUTHORIZATION:-}" ]]; then auth=(-H "Authorization: $SEMANTIC_TEST_AUTHORIZATION"); fi
curl --fail --silent --show-error "${auth[@]}" \
  -H 'Content-Type: application/json' \
  --data-binary @osi-fill-request.json "$fill_url" > osi-submit.json
cat osi-submit.json
```

从提交响应取 `vectorFillTaskId` 查询任务。

```bash
task_id=$(python3 -c 'import json; from uuid import UUID; print(UUID(json.load(open("osi-submit.json", encoding="utf-8"))["vectorFillTaskId"]))')
curl --fail --silent --show-error "${auth[@]}" "$fill_url/tasks/$task_id" > osi-status.json
cat osi-status.json
```

任务达到 `COMPLETED` 后做第 3 步。保存每个后端的提交和终态响应时使用各自的输出目录或文件名。1031 历史耗时约 PG 13 分钟、GV 34 分钟。GV 的 JDBC 批量计数缺陷曾把已填的 11,087 个语义目录向量报告成 178 个，终态达到后以库内非零数为准。

## 3. 查库确认后执行检索

将 `verify.sql` 传给对应测试库的 `psql` 或 `gsql`。下面命令复用第 1 步的变量和已配置的数据库认证。

```bash
docker exec -i "$PG_CONTAINER" psql -p "$PG_DB_PORT" -U "$PG_DB_USER" -d "$PG_DB" \
  -v ON_ERROR_STOP=1 < verify.sql

docker exec -i -u "$GV_OS_USER" -e "GAUSSHOME=$GV_GAUSSHOME" -e "LD_LIBRARY_PATH=$GV_LIB_PATH" "$GV_CONTAINER" \
  "$GV_GSQL" -p "$GV_DB_PORT" -U "$GV_DB_USER" -d "$GV_DB" \
  -v ON_ERROR_STOP=1 < verify.sql
```

本体三表和语义目录分别核对 `filled = total`，并确认 C-04 的两个主题值均有非零向量。1031 历史参考值为本体 13/13、实体 100/100、关系 70/70。语义目录共 11,087 个 m3 候选，其中表描述 108/108、列描述 1,053/1,053、值字面量 4,955/4,955。使用 API 重新导入本体后，按目标库实际总数检查。

## 版本依据

`prefill_ontology_vectors.py` 来源于 1031 转测目录的 `tools/t047b-fill-ontology-vectors.py` 后续修复版，对应 `fix/ontology-vector-prefill-v2` 的 `6d6bb75`。本包副本去掉历史实例的命令示例，支持指定数据库容器、容器内用户和端口。回填逻辑沿用原脚本。

`osi-fill-request.json` 按 1031 PG/GV 两边实际发出的参数保存。回填与计数依据来自 1031 自测材料的《04 单题功能验证记录》第 1、6 节和《07 本体三表向量 Prefill 可用性核对》。
