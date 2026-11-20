# 1031 本体检索测试用例

## 执行

导入业务数据和本体并填好向量后，在测试环境调用 `POST /api/semantic/v1/ontology/retrieve`。`requests/` 中七份 JSON 取自 2026-10-31 实测记录，同一用例的请求内容在 PG 和 GV 一致，可以分别对两个后端执行。

在 WSL / Bash 中进入本文件所在目录，把 `BASE_URL` 设为测试实例的服务地址（包括协议和端口），再执行三道首测题。每轮会新建一个结果目录，保存 HTTP 响应体并打印 HTTP 状态和耗时。分别对 PG 和 GV 执行，记录结果目录对应的后端。扩展到七题时，把 `for` 后的文件列表换成 `requests/*.json`。

```bash
: "${BASE_URL:?请先设置测试实例的 BASE_URL}"
auth=()
if [[ -n "${SEMANTIC_TEST_AUTHORIZATION:-}" ]]; then auth=(-H "Authorization: $SEMANTIC_TEST_AUTHORIZATION"); fi
OUT_DIR="$(mktemp -d)"
for req in requests/C-01.json requests/C-04.json requests/C-06-explicit.json; do
  name="$(basename "$req" .json)"
  curl --silent --show-error --max-time 900 "${auth[@]}" \
    --header 'Content-Type: application/json' \
    --data-binary "@$req" \
    --output "$OUT_DIR/$name.json" \
    --write-out "$name HTTP %{http_code} %{time_total}s\n" \
    "${BASE_URL%/}/api/semantic/v1/ontology/retrieve"
done
printf '响应目录 %s\n' "$OUT_DIR"
```

## 验收口径和实测结果

优先跑 **C-01、C-04、C-06-explicit**。HTTP 200 后，同时检查 `dataAccessPlan.tables`、`joinPaths` 的列和方向，以及问句需要的过滤条件或聚合口径。记录 `coverage`、路由和快路情况，以便定位同一问句的差异。

| 请求 | 预期检查 | 1031 实测 |
|---|---|---|
| [`C-01`](requests/C-01.json) | 指定 `cordis_eval`。六张表串起 `erc_panels → project_erc_panels → projects → project_members → institutions → countries`，能覆盖评审组 `LS%` 和国家 `Spain` 两个条件。注意物理列是 `project_erc_panels.project`。 | PG/GV 均返回六表及五条业务连接。PG 八条、GV 七条 JOIN，含反向重复；PG 报 `unsatisfied`，GV 报 `degraded`。 |
| [`C-04`](requests/C-04.json) | `projects`、`project_topics`、`topics`，应能用两个 FETOPEN 主题代码求项目交集。核对 `project_topics.project = projects.unics_id`、`project_topics.topic = topics.code`。 | PG/GV 回填后的响应均有三表和两条业务连接。各有一条反向重复边，并报告 `coverage=unsatisfied`。词值回退列仍需核查。 |
| [`C-06-explicit`](requests/C-06-explicit.json) | 指定 `cordis_eval`。检查 `project_members.institution_id = institutions.unics_id`、`institutions.country_id = countries.unics_id`，能按国家聚合去重机构。 | PG 1/1、GV 3/3 返回完整三表链路。部分响应有反向重复边，`coverage` 仍为 `unsatisfied`。 |
| [`C-06-default`](requests/C-06-default.json) | 同上，省略 `ontology_name`，观察自动路由和完整率。宜多次执行，记录是否命中快路。 | PG 历史对照只返回 `countries`。GV 默认配置 2/5 完整，关闭快路后 1/3 完整。 |
| [`Q1-filter`](requests/Q1-filter.json) | `projects` 应提供 `start_date`、`total_cost`，能落实启动时间与总经费过滤。 | PG/GV 均命中快路，拉入额外表和无别名的 `programmes` 自连接，指引为空。 |
| [`Q2-aggregation`](requests/Q2-aggregation.json) | 1031 按 `programme` 理解“资助计划”，应具备 `projects → project_programmes → programmes` 连接，支持按计划计项目数。 | PG/GV 均给出基础链路，同时出现额外表、反向重复和同表自连接，指引为空。 |
| [`Q3-institution-topic`](requests/Q3-institution-topic.json) | 检查 `institutions → project_members → projects → project_topics → topics`，要求主题代码 `FETOPEN-1-2014` 能落到正确的主题列。 | PG/GV 均有五表，去掉重复边后业务链路可用。指引为空，词值回退列有偏差。 |

## 金标 SQL

[`cases_v2.json`](cases_v2.json) 保留 1030 原始八题自然语言和 `golden_sql`，接口复跑用 `requests/` 的原始请求。三道核心题也可直接在已导入 CORDIS 业务表的测试库中执行。[C-01](golden/C-01.sql) · [C-04](golden/C-04.sql) · [C-06](golden/C-06.sql)

这三个 SQL 文件开头设置 `search_path` 到 CORDIS 的物理 schema `unics_cordis`。C-06 保留历史金标的 `institutions JOIN countries` 口径。1031 接口实测按「参与过项目的机构」检查，并要求 `project_members`。若做最终结果对比，先确认计数口径。

## 历史响应

[`historical-1031.json`](historical-1031.json) 从 19 份历史响应提取表、连接、路由和诊断计数。`source` 是 `Dailytest/selftest-1031/artifacts/` 下的原始文件路径，便于回查。PG 自动路由失败和 GV 关闭快路的对照结果见 1031 原始逐题记录第 4 节。
