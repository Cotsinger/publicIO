# 1031 本体检索转测 FAQ

适用于转测发布包 `semantic-layer-0.2.0-20261031-SNAPSHOT.tar.gz`，对应 `semantic-service@df217b9a`。1030 是此前准备记录的日期。开测顺序为导入本体 JSON、回填向量、查库核验、发检索请求。基础数据、执行步骤和已验证范围见[转测入口](README.md)及[验证记录](VERIFIED.md)。

## 1. 本地 BGE-M3 怎么配置

1031 的 PG 和 GV 都用本机运行的 `BAAI/bge-m3`。配置中的 `openai` 表示 OpenAI 兼容 HTTP 协议，目标是本机模型服务 `127.0.0.1:8082`，没有用外部 OpenAI 服务或 Key。在 `conf/semantic-service-application.properties` 配置以下参数。

```properties
semantic_service.vector.embedding.service.enable=true
semantic_service.vector.embedding.bge_base.enable=false
semantic_service.vector.embedding.m3.provider=openai
semantic_service.vector.embedding.m3.openai.base-url=http://127.0.0.1:8082/v1
semantic_service.vector.embedding.m3.openai.model=BAAI/bge-m3
semantic_service.vector.embedding.m3.openai.api-key=
```

模型服务先加载本地权重，再开放 `/v1/embeddings`。HTTP 请求的 `model` 填服务注册的模型名。模型服务的启动参数才填磁盘目录。若 Java 和 BGE 不在同一个容器，配置容器能访问的地址。Java 的 `base-url` 填到 `/v1`。手测和预填充脚本的 `--embed-url` 填到 `/v1/embeddings`。

如果要求 Java 在进程内加载，将 `m3.provider` 改为 `local`，并配置 `semantic_service.vector.embedding.m3.model.path=/opt/models/bge-m3`。目录应放 DJL 能加载的主编码器 TorchScript `model.pt` 和配套 `tokenizer.json`。Hugging Face 的原始权重需要先导出成兼容的 TorchScript。1031 实测采用本机 HTTP 路径，Java 直加载路径做过代码核对。包里的 Python 本体三表脚本仍按 `--embed-url` 请求模型服务。[BGE-M3 官方权重](https://huggingface.co/BAAI/bge-m3/tree/main)

### PowerShell 探针

在与 `semantic-service` 网络可达性一致的环境执行。原自测输入为一中一英两条文本，预期两行结果，每行 1024 维，L2 范数接近 1。

```powershell
$body = @{ model = 'BAAI/bge-m3'; input = @('项目参与方', 'project participant') } |
    ConvertTo-Json -Compress
$result = Invoke-RestMethod -Uri 'http://127.0.0.1:8082/v1/embeddings' `
    -Method Post -ContentType 'application/json; charset=utf-8' `
    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120

$result.data | ForEach-Object {
    $v = $_.embedding
    $sum = 0.0
    foreach ($x in $v) { $sum += $x * $x }
    [pscustomobject]@{ Index = $_.index; Dimensions = $v.Count; Norm = [Math]::Sqrt($sum) }
}
```

连接拒绝时检查服务监听和容器地址。`404` 时核对 `/v1/embeddings` 和注册的模型名。返回 768 维时检查是否连到了 BGE Base。嵌入请求用 `input`，本体检索请求用 `query`。

## 2. 1031 实测参数

| 项目 | 1031 实测设置 |
|---|---|
| PG | 服务 `31100`，数据库端口 `5433`，`semantic_layer_1031_pg`，能力探测 `strict` |
| GV | 服务 `31101`，数据库端口 `5678`，`semantic_layer_1031_gv`，PG 兼容模式，能力探测 `optional` |
| 语义库 | 两边都用 `public` schema。19 张 CORDIS 业务表在 `unics_cordis` |
| 向量 | `BAAI/bge-m3`，1024 维。历史本机脚本截断 512 tokens，取 CLS 并做 L2 归一化。召回的 768 维 BGE Base 通道关闭 |
| 问句 LLM | 两套留存配置均为 `GLM-5.3-Flash`、`temperature=0`、`stream=true`、`reasoning_effort` 留空。测试填自己的 `/v1/chat/completions` 网关。历史报告也记录使用过 `ds-v4.1-flash-1017`，响应留档无法逐题归属 |
| 检索 | 快路默认开，关闭只用于对照。`vote-gap=1`、`leading-rank-gap=2`、`verify-rounds=3`、`loop.budget=2`。请求传 `query` 与可选 `ontology_name`，主测客户端超时 900 秒 |
| OSI 回填 | `model=m3`、`logicalTable=all`、`dryRun=false`、`batchSize=64`、`upsert=true`。Java 调 BGE 的 HTTP 子批最多 32 条 |

本体导入和向量验证可以先单独执行。含 LLM 的检索用例还需要可用的问句模型服务。[回填请求](vectors/osi-fill-request.json) · [检索用例](cases/README.md)

## 3. 两种回填怎么查库

两个操作都更新已有记录，行数通常不变。本体三表脚本的 `--apply` 填本体、实体、关系定义的 `search_vector_m3`。OSI `/api/semantic/v1/osi/fill-vectors` 填语义目录的表描述、列描述、词值等向量。PG/GV 均可在测试库执行以下只读 SQL。

```sql
SELECT current_database();

SELECT api_name, vector_norm(search_vector_m3)
FROM public.t_semantic_ontology_definition;

SELECT value, vector_norm(value_vector_m3)
FROM public.t_semantic_data_column_value
WHERE table_name_en = 'project_topics'
LIMIT 5;
```

只导入两个主测本体时，第一条业务查询预期返回 `cordis_eval`、`cordis_eval_org` 两行，范数都接近 `1`。如果加四个分域，共六行。`0` 或 `NULL` 表示还没填到。查不到行时核对连接的库和前置导入。三表全量预期覆盖率为 `2/2、11/11、9/9`，六本体时为 `6/6、30/30、21/21`。OSI 先等任务 `COMPLETED`，GV 实测遇到过任务计数少报，验收以查库的非零向量数为准。[完整核验 SQL](vectors/verify.sql) · [回填说明](vectors/README.md)

## 4. `confidence`、大小写与无关问句

`ontologyContext.confidence` 是**最后一轮的本体域路由判定**。`reliable` 表示这一轮选定了本体域。业务取数是否完整还要检查 `coverage`、`dataAccessPlan.tables` 和 `joinPaths`。1031 的 C-06 有过 `reliable` 但只返回 `countries` 的实测结果。[历史响应摘要](cases/historical-1031.json)

| `ontology_name` 输入 | 1031 行为 |
|---|---|
| 传存在的名字 | 显式预检命中即得 `reliable / explicit_precheck`。数据库精确查询按 `lower(api_name) = lower(?)`，所以 `CORDIS_EVAL` 也能找到 `cordis_eval`。后续部分域筛选按原字符串比较，转测统一传录入的 `api_name` 原样 |
| 不传 | 走自动路由。精确命中、域投票或名次领先等可选出可靠域。最后一轮没有选定可靠域，外层才写 `none` |
| 传不存在的名字 | 显式预检判 `unreliable`，记 `routing.warning`，进入开放探索，这条分支的外层标为 `none` |

`diagnostic.reasoningTrace.routing` 记录首轮的 `level`、`triggeredBy`、`domain` 和 `warning`。发生回环时，用 `satisfactionLoop` 查各轮变化。

完全无关的问句仍可触发整句相似度召回，可能出现弱相关候选。首轮本体通道默认 `topK=15`，它是候选上限。最终 Bundle 再筛选，缺少 `keep.ontologies` 时本体、实体、关系各保留最多 5 条。负例重点查最终是否把无关候选放进了 `dataAccessPlan`，以及缺口有没有如实体现。

## 5. 语义检索兜底与停止条件

1031 的 `POST /api/semantic/v1/ontology/retrieve` 在**同一次请求内**切到开放探索。开放探索可用 `search_tables`、`search_columns` 等工具，服务不另发独立的 `POST /api/semantic/v1/semantic/retrieve` 请求。路由不可靠或有歧义可以直接开放探索。本体受限模式有硬缺口，重检无增量或预算耗尽时也可升级。

- `semantic_service.retrieval.ontology.loop.trust-llm-final=true` 是默认值。如果 LLM 已给出最终选择，它允许把原本的 `RETRY` 改为 `FINISH`，缺口仍出现在 `coverage`。这条规则不拦截 `ESCALATE_OPEN`。
- `semantic_service.retrieval.ontology.fast-path.enabled=false` 只会关掉快路。1031 本体链路没有独立的「无本体命中即停止」开关。

测试记录建议保留 `diagnostic.reasoningTrace.satisfactionLoop` 和 `diagnostic.toolTrace`。前者用来确认是否 `escalate_open`，后者用来确认是否实际调用了表列工具。
