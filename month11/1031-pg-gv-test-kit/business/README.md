# 新测试库的业务数据和目录准备

已有 CORDIS 业务表和语义目录可直接回到[本体接口导入](../README.md#2-从接口导入本体)。以下命令针对两套独立的、已新建的空测试数据库。安装或启动语义服务时使用测试方自己的账号、认证和配置。命令在本目录的 Bash 中执行，使用可访问目标数据库的容器及客户端。保持 `set -o pipefail` 以便发现导入管道中的错误。

业务文件恢复到 `unics_cordis` schema，语义元数据恢复到 `public`。`../catalog/cordis-osi.sql.gz` 是 1031 实测所用 CORDIS 表列和词值的补充件，包含 `4955` 条值和 `20` 条已登记的列连接。它按原 ID 导入，适用于空白语义目录。已采集真实目录的现有库应直接使用其当前表列、连接、词值。完整表清单与计数见[目录数据统计](../catalog/row-counts.json)。

## PostgreSQL / ParadeDB

使用带有 `pg_search`、`pgvector`、`pg_trgm`、`uuid-ossp` 的环境。将 `PG_CONTAINER`、`PG_DB` 和 `PG_DB_USER` 设为测试实值，`PG_DB_PORT` 为容器内端口。为空库第一次部署服务时可使用随包的 1031 DDL；已有等价语义表时跳过 DDL 步骤。需要有创建扩展和导入数据的权限。

```bash
set -euo pipefail
pg=(docker exec -i -e 'PGOPTIONS=-c search_path=public' "${PG_CONTAINER:?}" psql -X -p "${PG_DB_PORT:?}" -U "${PG_DB_USER:?}" -d "${PG_DB:?}" -v ON_ERROR_STOP=1)
restore=(docker exec -i "$PG_CONTAINER" pg_restore -p "$PG_DB_PORT" -U "$PG_DB_USER" --no-owner --no-privileges)
"${pg[@]}" -v fts_config=simple -f - < create_semantic_layer.sql
"${restore[@]}" --section=pre-data --section=data --exit-on-error -d "$PG_DB" < cordis.pg.dump
docker exec -i "$PG_CONTAINER" pg_restore --section=post-data --no-owner --no-privileges --file=- < cordis.pg.dump |
  sed -E 's/unics_cordis\.(gist|gin)_trgm_ops/public.\1_trgm_ops/g' |
  "${pg[@]}" -f -
gzip -dc ../catalog/cordis-osi.sql.gz | "${pg[@]}" -f -
```

实际业务备份的 trigram 操作符类在 `unics_cordis`，1031 初始化 DDL 把 `pg_trgm` 安装到 `public`。上面的后置恢复只调整索引操作符类的 schema，保留备份中的业务数据和约束。

## GaussVector

新建库使用 `DBCOMPATIBILITY 'PG'` 和 UTF-8。把 `GV_CONTAINER`、`GV_OS_USER`、`GV_DB`、`GV_DB_USER`、`GV_DB_PORT` 以及容器内 `GV_GSQL`、`GV_LIB_PATH`、`GV_GAUSSHOME` 填写为测试实值。默认采用已配置的容器内数据库认证。1031 开发者版历史上将 `semantic.storage.capability-check` 设为 `optional`，服务账号需有启动期在 `public` 创建所需函数的权限。

```bash
set -euo pipefail
gv=(docker exec -i -u "${GV_OS_USER:?}" -e "GAUSSHOME=${GV_GAUSSHOME:?}" -e "LD_LIBRARY_PATH=${GV_LIB_PATH:?}" "${GV_CONTAINER:?}" "${GV_GSQL:?}" -X -p "${GV_DB_PORT:?}" -U "${GV_DB_USER:?}" -d "${GV_DB:?}" -v ON_ERROR_STOP=1)
"${gv[@]}" -f - < create_semantic_layer_gaussvector.sql
"${gv[@]}" -f - < cordis.gv-schema.sql
gzip -dc cordis.gv-data.sql.gz | "${gv[@]}" -f -
gzip -dc ../catalog/cordis-osi.sql.gz | "${gv[@]}" -f -
```

`create_semantic_layer_gaussvector.sql` 来自 1031 发布包，已把 schema 占位符替换为 `public`。`cordis.gv-schema.sql` 与数据件取自实际 PG → GV 转换后的 1031 导入文件。业务 schema 只保留实际导入的 19 张表、序列和兼容索引，移除了 GV 开发者版拒绝的四段 `WITH NO DATA` 物化视图定义。DDL 的 `subgraph_count` 警告在历史环境中曾出现，导入应以命令退出状态和业务数据核对为准。

## 导入后核对

PG 和 GV 都应有 19 张 CORDIS 业务表。可执行下方 SQL 检查几个关键表，以及运行[三题金标 SQL](../cases/README.md#金标-sql)。业务数据准备好、服务健康检查通过后，回到[本体 API 导入](../README.md#2-从接口导入本体)。

```sql
SELECT 'projects' AS name, COUNT(*) FROM unics_cordis.projects
UNION ALL SELECT 'institutions', COUNT(*) FROM unics_cordis.institutions
UNION ALL SELECT 'project_topics', COUNT(*) FROM unics_cordis.project_topics;
```

历史规模为 `projects=62679`、`institutions=61493`、`project_topics=58826`。
