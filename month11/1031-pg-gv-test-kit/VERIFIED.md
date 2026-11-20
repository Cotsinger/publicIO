# 1031 转测包验证记录

复核日期为 2026-11-20。参考运行包为 2026-10-31 nightly，对应 `df217b9a`，发布包 SHA-256 为 `f59fd68ded8c4b3a10722aea94160ebb76cfa1d39e8f7ec209f418f4dea5bd73`。可借助 `MANIFEST.sha256` 核对转交的文件。

## 本次复核

新建隔离测试库，使用本包业务档案和 CORDIS 语义目录。通过 1031 服务 REST 上传四个 CORDIS 分域和两个主测 JSON，核对逐场景对象名；通过本机 `BAAI/bge-m3` 写入 1024 维向量。当前复核包含以下事实。

| 检查 | PostgreSQL / ParadeDB | GaussVector |
|---|---|---|
| 业务表与目录 | 19 张业务表、19 张表目录，通过。 | 相同。 |
| 本体 REST 导入 | 六个场景；35/35 个表绑定已关联目录表 ID。 | 相同。 |
| 本体三表 m3 | 本体定义 6/6、实体 30/30、关系 21/21。 | 相同。 |
| OSI 表描述回填 | `data_table` 实际写入，任务 `COMPLETED`，查库 19/19 个非零向量。 | 相同。 |
| 三道金标 SQL | C-01 返回 72 行，C-04 返回 46 行，C-06 返回 5 行。 | 72、46、5 行。 |

两侧均以 dry-run 提交了 OSI 全量参数。此次实际执行的是表描述子范围，值字典等其余 OSI 类别沿用历史回填流程。问句 Bundle 的结果使用历史记录，隔离验证未接入测试 LLM。测试方按第 3 步完成全量回填后，可执行本包请求并按 [`cases/README.md`](cases/README.md) 进行验收。

## 1031 历史实测

- `Dailytest/selftest-1031/docs/本体基础检索1031-自测报告.md` 的部署和数据章节记录了 PG/GV 两库共同的 19 张业务表和 13 个历史本体。
- `Dailytest/selftest-1031/artifacts/07-ontology-prefill-check.md` 记录本体三表历史 m3 覆盖为 13/13、100/100、70/70。历史 OSI 回填为 11,087 个向量候选，两库以实际非零值为准。
- `Dailytest/selftest-1031/artifacts/04-cases.md` 保存检索判定，原始请求和响应同目录留档。本包 [`cases/historical-1031.json`](cases/historical-1031.json) 保留了相关历史响应的表、JOIN、覆盖及路由摘要。
