# 1031 本体基础检索转测包

适用对象为已部署 `semantic-service` 的 PG / GaussVector 测试实例。参考服务包为 `semantic-layer-0.2.0-20261031-SNAPSHOT.tar.gz`（nightly `df217b9a`），服务由测试环境提供。本体通过 `POST /api/semantic/v1/ontology/define/upload/json` 导入。业务表和检索所需的语义目录补充数据在 `business/`、`catalog/`。拷贝后可在 Bash 执行 `sha256sum -c MANIFEST.sha256` 核对文件。

## 1. 准备 CORDIS 业务表和语义目录

测试中常见的 BGE 本地配置、向量查库、`confidence` 和兜底行为见[转测 FAQ](FAQ.md)。

每个后端使用自己的测试服务和数据库。已经有 `unics_cordis` 的 19 张业务表、`cordis_temporary` 的表列目录、JOIN 边和值字典时，可沿用这批数据。新建测试库时按[数据库准备步骤](business/README.md)恢复本包的 CORDIS 业务数据和目录。检索服务应从测试库读取 `public` 下的语义元数据，配置测试方自己的 LLM 和嵌入服务。开始前确认 `GET /api/semantic/v1/health` 返回 HTTP 200。

## 2. 从接口导入本体

必传为 [`cordis_eval.json`](ontology/cordis_eval.json) 和 [`cordis_eval_org.json`](ontology/cordis_eval_org.json)。两份分别包含 **8 实体 / 7 关系**、**3 实体 / 2 关系**，每份 JSON 单独 POST。`cordis_eval_org` 保留 `Institution`、`Country` 与另一场景同名的结构，用于测试场景归属和自动路由。

可在支持文件上传的测试入口提交这两个 JSON，或从本目录在 Bash 中执行以下命令。`BASE_URL` 使用测试实例的服务根地址，包含协议和端口。需要鉴权时，把完整 `Authorization` 请求头值放在 `SEMANTIC_TEST_AUTHORIZATION` 环境变量中。

```bash
: "${BASE_URL:?填写测试服务根地址}"
python3 ontology/import_ontologies.py --base-url "$BASE_URL"
```

直接调用接口时，将任一文件作为 `application/json` 的请求体。导入时服务会同步绑定对象的语义目录，且同名场景会被替换，所以使用隔离测试实例。上面的脚本先用 `/scenes` 核对同名场景，并逐场景通过 `/object_list` 比对实体和关系名。若中途有一个场景成功，修正后只传尚未导入的文件，文件路径可作为脚本位置参数。

```bash
auth=()
if [[ -n "${SEMANTIC_TEST_AUTHORIZATION:-}" ]]; then auth=(-H "Authorization: $SEMANTIC_TEST_AUTHORIZATION"); fi
curl --fail --show-error --silent "${auth[@]}" -H 'Content-Type: application/json' \
  --data-binary @ontology/cordis_eval.json \
  "${BASE_URL%/}/api/semantic/v1/ontology/define/upload/json"
```

要检查多个 CORDIS 分域共存时的路由，在空白测试实例执行时加 `--with-cordis-baseline`。它会先传入 `ontology/cordis-baseline/` 中的分类、地域、参与者、项目四个分域，然后传两个主测本体。两个 JSON 中的 `cordis_temporary` 是语义目录里的逻辑库名。三段式 `cordis_temporary.unics_cordis.<table>` 用来复用已有表记录，测试库自己的连接由服务部署配置指定。

## 3. 回填向量

用同一套 `BAAI/bge-m3`（1024 维）完成两项回填。[PG/GV 回填命令和核验 SQL](vectors/README.md)

1. 运行 `vectors/prefill_ontology_vectors.py`，先 `--dry-run`，再 `--apply`，补齐本体定义、实体、关系三张表的 `search_vector_m3`。
2. 调用 `/api/semantic/v1/osi/fill-vectors`，补表、列和值字典等语义目录的 m3 向量。异步任务达到 `COMPLETED` 后再用 `vectors/verify.sql` 检查库内非零向量数，特别是 C-04 的两个主题值。

仅导入两个主测本体时，本体三张表的向量覆盖应为 **2/2、11/11、9/9**。在空库加四个 CORDIS 分域时为 **6/6、30/30、21/21**。1031 自测检索只启用了 m3 通道。

## 4. 跑测试题

先跑 **C-01（显式本体、六表链路）、C-04（双主题交集）、C-06-explicit（国家聚合）**。之后再检查 **C-06-default** 的自动路由，并跑 Q1–Q3。每题核对表集、物理 JOIN 列和业务条件。HTTP 200 只表示服务返回，1031 曾出现连接重复、`coverage` 与实际链路不一致、自动路由缺表。[实测请求、金标 SQL 和历史响应摘要](cases/README.md)

## 材料来源与复现范围

- `business/` 的业务数据来自 1031 PG/GV 当时用于导入的档案。`catalog/` 从当时的语义元数据导入件中提取 CORDIS 表、列、连接及词值，向量留给第 3 步。目录补充件不会注册任何本体。
- 主测 JSON 根据自测库中的定义、关系和数据表绑定重建。实体属性按业务表字段补齐，以满足 API 的必填校验。接口会分配新的对象 ID。JSON 标题字段取当时档案中的有效业务列。
- 历史完整环境包含 13 个场景，其中还有 7 个 NPD 场景。本包覆盖 CORDIS 两个主测本体及四个可选分域。自动路由的候选集会随导入范围变化，历史 Bundle 供对照。各题本轮验证范围见[验证记录](VERIFIED.md)。
