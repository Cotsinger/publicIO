-- ============================================================================
-- PostgreSQL 版语义层建表脚本（ParadeDB BM25 + pgvector + pg_trgm）
--
-- 目标数据库：库须由运维/平台提前建好（本脚本不建库）。schema 名由
--   semantic_service.db.schema-name 配置（默认 public），服务启动时通过 JDBC
--   执行本脚本幂等建表；gsql/psql 手动执行时对象落到当前 search_path 首个 schema。
--   见 docs/design/jdbc-schema-init-unification-design.md。
--
-- 执行示例（psql，库已提前建好）：
--   psql -h localhost -p 5432 -U postgres -d <dbname> -f create_semantic_layer.sql
--
-- 手动重建（清空已有数据）：先 DROP SCHEMA <name> CASCADE 再执行本脚本；
--   或直接使用服务启动参数 -c（语义相同）。
--
-- 与 GaussVector 版（create_semantic_layer_gaussvector.sql）的差异见该文末差异表。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- [库前提] 数据库须由运维/平台提前建好（本脚本不建库）。
--   - JDBC 路径：服务启动时借主库 DataSource 连接执行本脚本（幂等建表），
--     先探活（库不存在/不可连即启动失败）。
--   - 库名取自 semantic_service.db.url 末段，库提前建好且可连是运维前提。
--   - schema 统一由 Java 侧（check-then-create）负责；本脚本无建 schema 语句。
--   - 本脚本无任何 DROP 语句，幂等完全靠 IF NOT EXISTS，可安全重复执行。
-- ----------------------------------------------------------------------------

-- ============================================================================
-- [Schema 命名空间] 对象落库位置由执行方 search_path 决定：
--   - JDBC（服务启动/多场景）：SET search_path TO <target>, <shared>, pg_catalog
--   - psql 手动执行：默认 public（或先行 SET search_path TO <目标 schema>）
-- 多场景模式下 shared extension schema 不得存放语义表。
-- ============================================================================

-- ============================================================================
-- [环境准备] 启用必备的数据库扩展
-- 前置条件：扩展须已在 PostgreSQL 所在系统安装，否则会报：
--   "The extension must first be installed on the system where PostgreSQL is running."
--   - uuid-ossp: 多数发行版在 postgresql-contrib 中；macOS: brew install postgresql
--   - vector (pgvector): 需单独安装；macOS: brew install pgvector
--   - pg_search (ParadeDB): BM25 全文检索扩展，提供 chinese_lindera 中文分词器；各检索通道表的
--       全文召回（search_text）由它承担，替代 pg_trgm 的子串模糊匹配（trgm 仅保留用于短标识/编码容错）
--   - Docker（推荐）: 使用 ParadeDB 官方镜像 paradedb/paradedb（已内置 pgvector + pg_search + pg_trgm），
--       可一并替代单独的 pgvector 镜像
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_search;  -- ParadeDB BM25 全文检索（中文用 chinese_lindera 分词器）

-- ============================================================================
-- [zhparser 引导]（可选扩展；自守卫、幂等）：装有 zhparser 时自动注册扩展 +
--   名为 'zhparser' 的 ts_config + 26 词性映射（配置名必须叫 'zhparser' 才能
--   命中检测，扩展自带 zhcfg 不符；无映射分词输出为空）；未装或执行失败仅
--   NOTICE 并降级 simple（勿移除异常处理）。执行时机：Java 层按
--   $zhparser_bootstrap$ 标签提取本块，先于 :'fts_config' 检测在 shared
--   schema 下执行（表 DDL 阶段跳过）；psql 手动执行时本块自然执行。
-- ============================================================================
DO $zhparser_bootstrap$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions WHERE name = 'zhparser') THEN
        RAISE NOTICE 'zhparser extension files not available, skipping bootstrap';
        RETURN;
    END IF;
    CREATE EXTENSION IF NOT EXISTS zhparser;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_ts_config WHERE cfgname = 'zhparser') THEN
        CREATE TEXT SEARCH CONFIGURATION zhparser (PARSER = zhparser);
    END IF;
    ALTER TEXT SEARCH CONFIGURATION zhparser
        DROP MAPPING IF EXISTS FOR n, v, a, i, e, l, j, o, r, w, u, m, t, h, k, d, x, b, f, c, p, q, s, z, y, g;
    ALTER TEXT SEARCH CONFIGURATION zhparser
        ADD MAPPING FOR n, v, a, i, e, l, j, o, r, w, u, m, t, h, k, d, x, b, f, c, p, q, s, z, y, g
        WITH simple;
    RAISE NOTICE 'zhparser FTS config ready';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'zhparser bootstrap skipped: %', SQLERRM;
END
$zhparser_bootstrap$;

-- ============================================================================
-- 全文检索 regconfig（仅 knowledge_evidence_edge 的 search_vector 仍用 tsvector；
--   knowledge_evidence 等 7 张检索通道表的全文召回已统一改用 pg_search 的 BM25 + chinese_lindera）
-- - 默认使用 PostgreSQL 内置 'simple'，保证未装 zhparser 时本脚本可直接执行。
-- - 使用默认 simple 时，应用侧请设置 KNOWLEDGE_EVIDENCE_TS_CONFIG=simple，与库内 regconfig 一致。
-- - 需要中文分词（zhcfg）时：先执行 python/semantic_layer/scripts/semantic_layer/init_fts_zhparser.sql，
--   再将本文件 knowledge_evidence_edge 的 to_tsvector 第一个参数由 'simple' 改为 'zhcfg'，并设置 KNOWLEDGE_EVIDENCE_TS_CONFIG=zhcfg。
-- ============================================================================

-- ============================================================================
-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
-- zhparser 检测：JDBC 路径由 Java 层在执行前检测 pg_ts_config 并把 :'fts_config'
--   替换为 'zhparser'/'simple'（SchemaProvisioner/StorageInitializer 的 prepareSql，
--   检测前会先在 shared schema 下执行上方引导块——装了 zhparser 的环境自动注册）；
--   psql 手动执行时引导块自然执行，但仍须先把本文件的 :'fts_config' 全部替换为
--   'zhparser'/'simple'（:'fts_config' 是 psql 变量语法，直接执行会报语法错误）。
-- ============================================================================

-- 第一部分：【点表】核心业务实体 (Node Tables)
-- ============================================================================

-- 1. 业务术语与逻辑实体表 (Semantic Terms)
-- 统一企业黑话与高度抽象的业务实体
CREATE TABLE IF NOT EXISTS t_semantic_term (
    term_id UUID CONSTRAINT pk_term PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL CONSTRAINT uk_term_name UNIQUE,
    domain VARCHAR(100), -- 所属业务域（如 Finance 财务, Growth 增长）。帮助 Agent 在多义词冲突时限定上下文范围。     
    synonyms TEXT[],  -- 同义词库。（如 ["GMV", "流水", "交易总额"]），扩展 Agent 的识别能力
    related_entity_type_id UUID, -- 关联的实体类型（多个术语可指向同一实体类型，FK 在 entity_type 创建后添加）
    term_vector vector(768),        -- 术语语义向量（bge-base-zh-v1.5，768 维）
    term_vector_m3 vector(1024),    -- 术语语义向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_term_term_vec
    ON t_semantic_term USING hnsw (term_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE term_vector IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_term_term_vec_m3
    ON t_semantic_term USING hnsw (term_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE term_vector_m3 IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_term_synonyms_gin
    ON t_semantic_term USING gin (synonyms)
    WHERE synonyms IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_term_name_trgm
    ON t_semantic_term USING gin (name gin_trgm_ops);
-- 全文召回：BM25（pg_search）覆盖术语名 + 同义词数组，chinese_lindera 分词 + 相关性排序
-- （synonyms 精确命中仍走上面的数组 GIN；name 短子串容错仍走上面的 trgm）
CREATE INDEX IF NOT EXISTS idx_term_bm25 ON t_semantic_term
    USING bm25 (term_id, name, synonyms)
    WITH (
        key_field = 'term_id',
        text_fields = '{"name": {"tokenizer": {"type": "chinese_lindera"}}, "synonyms": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
-- semantic_term 用 name 列（TermChannel 的 bm25SearchColumn="name"）
CREATE INDEX IF NOT EXISTS idx_term_name_gin ON t_semantic_term
    USING gin (to_tsvector(:'fts_config', name));

CREATE INDEX IF NOT EXISTS idx_term_domain
    ON t_semantic_term (domain)
    WHERE domain IS NOT NULL;

-- 2. 数据表 (Physical Entities: Tables & Views)
-- 描述业务数据所在底层数据仓库的物理存储位置
CREATE TABLE IF NOT EXISTS t_semantic_data_table (
    entity_id UUID CONSTRAINT pk_data_table PRIMARY KEY DEFAULT uuid_generate_v4(),
    entity_type VARCHAR(50) CHECK (entity_type IN ('PhysicalTable', 'VirtualView')), -- 物理类型（PhysicalTable 物理表, VirtualView 逻辑视图）
    schema_name VARCHAR(100),              -- 物理模式名（如 public, dwd）
    table_name TEXT NOT NULL,      -- 真实的物理表名
    table_name_en TEXT,            -- 英文/逻辑表名（与 type.json、ingestion、data_column.table_name_en 对齐）
    db_name_en VARCHAR(100),               -- 业务/逻辑库名英文（与 ingestion、data_column.db_name_en、AdvancedSearch 过滤一致）
    table_id TEXT,                 -- 逻辑表标识（与 type.json data_table.table_id、列侧 table_id 对齐）
    source_type VARCHAR(100),
    table_name_ch TEXT,
    table_description TEXT,
    ddl TEXT,
    -- 表描述语义检索：table_description 的 embedding（与 type.json vectorIndex:"true" 对齐）
    table_description_vector vector(768),        -- 表描述向量（bge-base-zh-v1.5，768 维）
    table_description_vector_m3 vector(1024),    -- 表描述向量（bge-m3，1024 维，多模型 RRF 召回）
    layer VARCHAR(50) CHECK (layer IN ('ODS', 'DWD', 'DWS', 'ADS')), -- 数仓分层（如 ODS, DWD, DWS），指导 Agent 优先选择加工好的高质量数据。
    column_descriptions TEXT,             -- 该实体表所有列名及其描述，格式：列名(类型): 描述；列名(类型): 描述；…
    qualified_name TEXT,          -- 全限定表名（如 postgres.public.orders_smoke）；供 AdvancedSearch table-relations-path 等解析
    data_retention_period_days INT,       -- 源系统中的留存期；NULL 表示未配置
    table_properties JSONB,               -- 表级语义组织元数据（dataset.custom_extensions.table_properties）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_data_table_db_en_schema_table UNIQUE(db_name_en, schema_name, table_name)
);

CREATE INDEX IF NOT EXISTS idx_data_table_desc_vec
    ON t_semantic_data_table USING hnsw (table_description_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_data_table_desc_vec_m3
    ON t_semantic_data_table USING hnsw (table_description_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE table_description_vector_m3 IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_data_table_table_id
    ON t_semantic_data_table (table_id) WHERE table_id IS NOT NULL;

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(table_name, '') || ' ' || COALESCE(table_name_en, '') || ' ' ||
    COALESCE(db_name_en, '') || ' ' || COALESCE(table_name_ch, '') || ' ' ||
    COALESCE(table_description, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(layer, '') || ' ' ||
    COALESCE(column_descriptions, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_data_table_search_text_trgm
    ON t_semantic_data_table USING gin (search_text gin_trgm_ops);

-- 原地升级注意：generated column 表达式变更（如本版加入 table_name_ch）对已有库不生效——
-- ADD COLUMN IF NOT EXISTS 会跳过已存在列。老库升级需先
--   ALTER TABLE t_semantic_data_table DROP COLUMN search_text_bm25;
-- 再重放下方 ALTER（并重建 bm25 索引），或直接用 start.sh -c 删库重建。
ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(table_name, '') || ' ' || COALESCE(table_name_ch, '') || ' ' || COALESCE(table_description, '')
) STORED;
-- 全文召回：BM25（pg_search），chinese_lindera 中文分词 + 相关性排序，替代 trgm 子串匹配
CREATE INDEX IF NOT EXISTS idx_data_table_bm25 ON t_semantic_data_table
    USING bm25 (entity_id, search_text_bm25)
    WITH (
        key_field = 'entity_id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
CREATE INDEX IF NOT EXISTS idx_data_table_search_text_gin ON t_semantic_data_table
    USING gin (to_tsvector(:'fts_config', search_text_bm25));

CREATE INDEX IF NOT EXISTS idx_data_table_ddl_trgm
    ON t_semantic_data_table USING gin (ddl gin_trgm_ops);

-- 已有库升级（新增 table_name_en / db_name_en / table_id / data_retention_period_days）：
--   ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS table_name_en TEXT;
--   ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS db_name_en VARCHAR(100);
--   ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS table_id TEXT;
--   ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS data_retention_period_days INT;
--   ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS table_properties JSONB;
--   CREATE UNIQUE INDEX IF NOT EXISTS idx_data_table_table_id ON t_semantic_data_table (table_id) WHERE table_id IS NOT NULL;
--
-- 自更老 schema 升级：若仍存在已废弃的库名列，将其非空值合并入 db_name_en 后删除该列，并确保 UNIQUE 为 (db_name_en, schema_name, table_name)（旧约束名以 \\d data_table 为准）。

-- 已有库升级（未重建表时）：
-- ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS table_description_vector vector(768);
-- 然后执行上面 idx_data_table_desc_vec 的 CREATE INDEX（若不存在）。

-- 3. 业务列表 (Data Columns)
-- 描述业务实体（semantic_term）的具体属性，承接物理列与业务概念的映射。通常通过table_has_column边表关联到data_table
CREATE TABLE IF NOT EXISTS t_semantic_data_column (
    dimension_id UUID CONSTRAINT pk_data_column PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    qualified_name TEXT,           -- Atlas/Referenceable 列唯一限定名（与 ingestion qualifiedName 一致）
    is_primary_key BOOLEAN DEFAULT FALSE,  -- 是否主键。让 Agent 知道该列是否可以作为 GROUP BY 或 DISTINCT 的依据
    -- 列语义检索：与 MetaVisor-main-2 DataColumn 的 column_description_short_vector 对齐（嵌入源优先 column_description_short）
    column_description_short_vector vector(768),       -- 列描述向量（bge-base-zh-v1.5，768 维）
    column_description_short_vector_m3 vector(1024),   -- 列描述向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    column_name_desc TEXT,
    column_description TEXT,
    column_description_short TEXT,
    column_description_medium TEXT,
    column_value_profile TEXT,             -- 字段值分布摘要，如取值范围、TopN、空值率、异常值说明等
    column_properties JSONB,                -- 列级语义组织元数据（field.custom_extensions.column_properties）
    synonyms TEXT[],
    value_nullable BOOLEAN DEFAULT TRUE,
    is_foreign_key BOOLEAN DEFAULT FALSE,
    db_name_en VARCHAR(100),               -- 业务库别名（英文），与 AdvancedSearch table-columns-info / column-value-info 两段式、三段式命名对齐
    table_name_en TEXT,          -- 物理表名（不含 schema），如 orders_smoke
    table_id TEXT,               -- 父 data_table 逻辑标识（对齐 Atlas type.json data_column.table_id）
    column_name_en TEXT,         -- 列名英文，如 order_id
    value_type TEXT NOT NULL,   -- 物理/逻辑类型（如 VARCHAR、bigint），供 Agent 引号与函数选择与过滤展示
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_data_column_db_table_column UNIQUE (db_name_en, table_name_en, column_name_en)
);

-- 已有库升级（保留 data_column 且曾含 data_type）：可先
--   UPDATE data_column SET value_type = COALESCE(NULLIF(TRIM(value_type), ''), data_type);
--   再 ALTER TABLE t_semantic_data_column DROP COLUMN IF EXISTS data_type;
--   并将 value_type 改为 NOT NULL（若仍需兼容可先填默认值再收紧约束）。
-- 已有库升级（新增 table_id）：ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS table_id TEXT;
-- 已有库升级（新增 qualified_name）：ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS qualified_name TEXT;
-- 已有库升级（新增 column_properties）：ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS column_properties JSONB;

CREATE INDEX IF NOT EXISTS idx_data_column_col_short_vec
    ON t_semantic_data_column USING hnsw (column_description_short_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_data_column_col_short_vec_m3
    ON t_semantic_data_column USING hnsw (column_description_short_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE column_description_short_vector_m3 IS NOT NULL;

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(column_name_desc, '') || ' ' || COALESCE(column_description, '') || ' ' ||
    COALESCE(column_description_short, '') || ' ' || COALESCE(column_name_en, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_data_column_search_text_trgm
    ON t_semantic_data_column USING gin (search_text gin_trgm_ops);

ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(column_description_short, '')
) STORED;
-- 全文召回：BM25（pg_search），chinese_lindera 中文分词 + 相关性排序
CREATE INDEX IF NOT EXISTS idx_data_column_bm25 ON t_semantic_data_column
    USING bm25 (dimension_id, search_text_bm25)
    WITH (
        key_field = 'dimension_id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
CREATE INDEX IF NOT EXISTS idx_data_column_search_text_gin ON t_semantic_data_column
    USING gin (to_tsvector(:'fts_config', search_text_bm25));


-- 已有库升级（未重建表时）：
-- ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS column_description_short_vector vector(768);
-- 然后执行上面 idx_data_column_col_short_vec 的 CREATE INDEX（若不存在）。

-- 3b. 列值表 (Data Column Values)
-- 对齐 Atlas type.json data_column_value：独立实体存放列值信息，通过 column_has_value 关系关联到 data_column
CREATE TABLE IF NOT EXISTS t_semantic_data_column_value (
    value_id UUID CONSTRAINT pk_data_column_value PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255),                   -- 展示名（与 Atlas/Referenceable、ingestion name 对齐）
    qualified_name VARCHAR(500),          -- 全限定名（与 ingestion qualifiedName、column_has_value 端点解析一致）
    value VARCHAR(255) NOT NULL,          -- 列取值（如 VIP、高价值客户）
    description TEXT,                     -- 列取值描述（如 高价值客户）；语义检索与 description_vector 对齐 main-2 data_column_value_enum
    description_vector vector(768),            -- 描述文本嵌入（bge-base-zh-v1.5，768 维）
    description_vector_m3 vector(1024),        -- 描述文本嵌入（bge-m3，1024 维，多模型 RRF 召回）
    column_name_en VARCHAR(200),               -- 所属列名（英文），与 data_column.column_name_en 对齐
    table_name_en TEXT,                         -- 所属物理表名（不含 schema），与 data_column.table_name_en 对齐
    db_name_en VARCHAR(100),                   -- 业务库别名（英文），与 data_column.db_name_en 对齐
    -- 兼容旧逻辑：按取值字面量的向量（可选）；列值语义检索主路径为 description_vector
    value_vector vector(768),                  -- 取值字面量向量（bge-base-zh-v1.5，768 维）
    value_vector_m3 vector(1024),              -- 取值字面量向量（bge-m3，1024 维，多模型 RRF 召回）
    value_type VARCHAR(50),                    -- 取值类型（如 enum），与 data_column.value_type 对齐
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_data_column_value_value_vec
    ON t_semantic_data_column_value USING hnsw (value_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_data_column_value_value_vec_m3
    ON t_semantic_data_column_value USING hnsw (value_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE value_vector_m3 IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_data_column_value_desc_vec
    ON t_semantic_data_column_value USING hnsw (description_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_data_column_value_desc_vec_m3
    ON t_semantic_data_column_value USING hnsw (description_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE description_vector_m3 IS NOT NULL;
-- 已有库升级（未重建表时）：ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS value_vector vector(768);
-- 然后执行上面 idx_data_column_value_value_vec 的 CREATE INDEX（若不存在）。
-- ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS description_vector vector(768);
-- 然后执行 idx_data_column_value_desc_vec 的 CREATE INDEX（若不存在）。
CREATE INDEX IF NOT EXISTS idx_data_column_value_column
    ON t_semantic_data_column_value (column_name_en, table_name_en, db_name_en);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE("value", '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_data_column_value_search_text_trgm
    ON t_semantic_data_column_value USING gin (search_text gin_trgm_ops);

ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE("value", '') || ' ' || COALESCE(description, '')
) STORED;
-- 全文召回：BM25（pg_search），chinese_lindera 中文分词 + 相关性排序
CREATE INDEX IF NOT EXISTS idx_data_column_value_bm25 ON t_semantic_data_column_value
    USING bm25 (value_id, search_text_bm25)
    WITH (
        key_field = 'value_id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
CREATE INDEX IF NOT EXISTS idx_data_column_value_search_text_gin ON t_semantic_data_column_value
    USING gin (to_tsvector(:'fts_config', search_text_bm25));

-- 已有库升级（新增 name / qualified_name）：  
--   ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS name VARCHAR(255);  
--   ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS qualified_name VARCHAR(500);

-- 4. SQL 过程点表 (sql_process)
-- 对齐 MetaVisor type.json：sql_process（superTypes Process）；用于登记 Golden SQL / 典型查询及其用到的列
CREATE TABLE IF NOT EXISTS t_semantic_sql_process (
    process_id UUID CONSTRAINT pk_sql_process PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(500),                   -- 展示名（与 Atlas/Referenceable、ingestion name 对齐）
    qualified_name VARCHAR(500),         -- 全限定名（与 Atlas/Referenceable、ingestion qualifiedName 端点解析一致）
    sql_id VARCHAR(255) NOT NULL,            -- 业务侧 SQL 标识，与 expression 均在 Atlas 上标为唯一
    expression TEXT NOT NULL,              -- SQL 文本或规范化表达式
    source_tables TEXT[],                   -- SQL 过程源表
    target_table TEXT,                      -- SQL 过程目标表
    intent TEXT,                           -- 可检索的意图摘要
    query TEXT,                            -- 自然语言问法或检索文本；可选建向量索引
    query_vector vector(768),          -- NL 问法向量（bge-base-zh-v1.5，768 维）
    query_vector_m3 vector(1024),      -- NL 问法向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_sql_process_sql_id UNIQUE (sql_id)
);

CREATE INDEX IF NOT EXISTS idx_sql_process_intent_trgm ON t_semantic_sql_process USING gin (intent gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_sql_process_query_trgm ON t_semantic_sql_process USING gin (query gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_sql_process_query_vector_hnsw
    ON t_semantic_sql_process USING hnsw (query_vector vector_cosine_ops)
    WHERE (query_vector IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sql_process_query_vector_hnsw_m3
    ON t_semantic_sql_process USING hnsw (query_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE (query_vector_m3 IS NOT NULL);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_sql_process ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(sql_id, '') || ' ' || COALESCE(intent, '') || ' ' ||
    COALESCE(query, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_sql_process_search_text_trgm
    ON t_semantic_sql_process USING gin (search_text gin_trgm_ops);

ALTER TABLE t_semantic_sql_process ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(intent, '') || ' ' || COALESCE(query, '')
) STORED;
-- 全文召回：BM25（pg_search），chinese_lindera 中文分词 + 相关性排序
CREATE INDEX IF NOT EXISTS idx_sql_process_bm25 ON t_semantic_sql_process
    USING bm25 (process_id, search_text_bm25)
    WITH (
        key_field = 'process_id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
CREATE INDEX IF NOT EXISTS idx_sql_process_search_text_gin ON t_semantic_sql_process
    USING gin (to_tsvector(:'fts_config', search_text_bm25));


CREATE TABLE IF NOT EXISTS t_semantic_knowledge_evidence (
    evidence_id UUID CONSTRAINT pk_knowledge_evidence PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,            -- 证据标题（如：Q3财报营收对齐会议纪要）
    evidence_type VARCHAR(50) CHECK (
        evidence_type IS NULL
        OR evidence_type IN ('Golden_SQL', 'Meeting_Note', 'Wiki_Rule')
    ),                                     -- 证据类型：语义上的证据类别；无法明确时可置 NULL
    raw_text TEXT NOT NULL,                -- 原始文本语料
    confidence_score INT CHECK (confidence_score BETWEEN 0 AND 100), -- 置信度（0-100），用于召回排序
    embedding vector(1024),                -- 文本向量，使用 BAAI/bge-m3 (1024 维) 进行相似度检索
    -- schema-free 抽取结果：实体与关系
    entities JSONB NOT NULL DEFAULT '[]'::jsonb,
    relations JSONB NOT NULL DEFAULT '[]'::jsonb,
    -- 图检索索引键（从 entities/relations 归一化提取，便于 GIN overlap 检索）
    entity_keys TEXT[] NOT NULL DEFAULT '{}',
    relation_keys TEXT[] NOT NULL DEFAULT '{}',
    -- 全文召回改由下方 search_text 上的 BM25 索引（pg_search + chinese_lindera）承担，
    -- 不再使用 simple 配置的 tsvector（对中文不分词、排序质量差）
    status VARCHAR(20) DEFAULT 'Active',
    expression TEXT,
    intent TEXT,
    query TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_knowledge_evidence_name UNIQUE (name)
);

-- 针对证据表建立向量索引 + 常用过滤索引，支持毫秒级相似度召回与快速过滤
CREATE INDEX IF NOT EXISTS idx_evidence_vector_hnsw ON t_semantic_knowledge_evidence USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_evidence_type_status ON t_semantic_knowledge_evidence (evidence_type, status);
CREATE INDEX IF NOT EXISTS idx_evidence_entity_keys ON t_semantic_knowledge_evidence USING gin (entity_keys);
CREATE INDEX IF NOT EXISTS idx_evidence_relation_keys ON t_semantic_knowledge_evidence USING gin (relation_keys);
CREATE INDEX IF NOT EXISTS idx_evidence_entities_jsonb ON t_semantic_knowledge_evidence USING gin (entities);
CREATE INDEX IF NOT EXISTS idx_evidence_relations_jsonb ON t_semantic_knowledge_evidence USING gin (relations);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_knowledge_evidence ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(raw_text, '')
) STORED;
-- 全文召回：BM25（pg_search），chinese_lindera 中文分词 + 相关性排序（取代原 simple tsvector）
CREATE INDEX IF NOT EXISTS idx_knowledge_evidence_bm25 ON t_semantic_knowledge_evidence
    USING bm25 (evidence_id, search_text_bm25)
    WITH (
        key_field = 'evidence_id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
CREATE INDEX IF NOT EXISTS idx_knowledge_evidence_search_text_gin ON t_semantic_knowledge_evidence
    USING gin (to_tsvector(:'fts_config', search_text_bm25));


-- knowledge_evidence 的规范化关系边（用于图查询）
CREATE TABLE IF NOT EXISTS t_semantic_knowledge_evidence_edge (
    edge_id UUID CONSTRAINT pk_knowledge_evidence_edge PRIMARY KEY DEFAULT uuid_generate_v4(),
    evidence_id UUID NOT NULL REFERENCES t_semantic_knowledge_evidence(evidence_id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,      -- chunk name，便于排查与回表聚合
    src TEXT NOT NULL,
    predicate TEXT NOT NULL,
    dst TEXT NOT NULL,
    edge_text TEXT NOT NULL DEFAULT '',   -- 人类可读的短句（检索与展示）
    edge_embedding vector(1024),          -- 与 chunk 相同：BAAI/bge-m3
    search_vector tsvector GENERATED ALWAYS AS (
        to_tsvector(
            'simple',
            COALESCE(edge_text, '')
                || ' ' || COALESCE(src, '')
                || ' ' || COALESCE(predicate, '')
                || ' ' || COALESCE(dst, '')
        )
    ) STORED,
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_knowledge_evidence_evidence_id_src_predicate_dst UNIQUE (evidence_id, src, predicate, dst)
);
CREATE INDEX IF NOT EXISTS idx_ke_edge_evidence_id ON t_semantic_knowledge_evidence_edge (evidence_id);
CREATE INDEX IF NOT EXISTS idx_ke_edge_src ON t_semantic_knowledge_evidence_edge (src);
CREATE INDEX IF NOT EXISTS idx_ke_edge_dst ON t_semantic_knowledge_evidence_edge (dst);
CREATE INDEX IF NOT EXISTS idx_ke_edge_predicate ON t_semantic_knowledge_evidence_edge (predicate);
CREATE INDEX IF NOT EXISTS idx_ke_edge_spd ON t_semantic_knowledge_evidence_edge (src, predicate, dst);
CREATE INDEX IF NOT EXISTS idx_ke_edge_src_trgm ON t_semantic_knowledge_evidence_edge USING gin (src gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_ke_edge_dst_trgm ON t_semantic_knowledge_evidence_edge USING gin (dst gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_ke_edge_predicate_trgm ON t_semantic_knowledge_evidence_edge USING gin (predicate gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_ke_edge_trgm_haystack ON t_semantic_knowledge_evidence_edge USING gin (
    (COALESCE(edge_text, '') || ' ' || COALESCE(src, '') || ' ' || COALESCE(predicate, '') || ' ' || COALESCE(dst, ''))
        gin_trgm_ops
);
CREATE INDEX IF NOT EXISTS idx_ke_edge_search_vector ON t_semantic_knowledge_evidence_edge USING gin (search_vector);
CREATE INDEX IF NOT EXISTS idx_ke_edge_embedding_hnsw ON t_semantic_knowledge_evidence_edge USING hnsw (edge_embedding vector_cosine_ops)
    WHERE (edge_embedding IS NOT NULL);

-- 6. 治理策略表 (Governance Policies)
-- 定义数据脱敏、过滤、屏蔽等治理策略，用于保护敏感数据
CREATE TABLE IF NOT EXISTS t_semantic_governance_policy (
    policy_id UUID CONSTRAINT pk_governance_policy PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,            
    policy_level VARCHAR(50) CHECK (policy_level IN ('Row', 'Column', 'Table')), -- 策略生效层级（如 Row 行级, Column 列级, Table 表级）
    enforcement_type VARCHAR(50) CHECK (enforcement_type IN ('Masking', 'Filtering', 'Block', 'Required', 'Pattern', 'Enum', 'Range', 'CustomValidate', 'Transform')), -- 执行类型（如 Masking 脱敏, Filtering 过滤, Block 屏蔽）
    rule_definition TEXT NOT NULL,         -- 具体的执行规则，大模型会根据这个定义（例如：将所有手机号替换为星号）去改写最终生成的sql
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_governance_policy ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(policy_level, '') || ' ' ||
    COALESCE(enforcement_type, '') || ' ' || COALESCE(rule_definition, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_governance_policy_search_text_trgm
    ON t_semantic_governance_policy USING gin (search_text gin_trgm_ops);

-- 7. 动作与工具表 (Agent Actions)
-- 定义具体的系统动作与工具，如查询、分析、报告生成等
CREATE TABLE IF NOT EXISTS t_semantic_agent_action (
    action_id UUID CONSTRAINT pk_agent_action PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL CONSTRAINT uk_agent_action_name UNIQUE,
    execution_mode VARCHAR(50) CHECK (execution_mode IN ('Sync', 'Async')), -- 执行模式（Sync 同步, Async 异步）告诉Agent调用后是应该原地等待结果，还是异步返回id
    endpoint VARCHAR(255),                  -- Action Service POST URL；执行 Sync 动作时应配置可达地址
    parameters_schema JSONB NOT NULL,       -- 参数定义规范，作为Function Call的元数据
    status VARCHAR(20) DEFAULT 'Active',
    logic TEXT,                   -- action的执行逻辑，如果不存在预制action，则需要根据这个logic生成action
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_agent_action ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(execution_mode, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_agent_action_search_text_trgm
    ON t_semantic_agent_action USING gin (search_text gin_trgm_ops);

-- 8. UDF 函数表 (Udf Functions)
-- 定义用户自定义函数，供 SQL 表达式中使用
CREATE TABLE IF NOT EXISTS t_semantic_udf_function (
    function_id UUID CONSTRAINT pk_udf_function PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,              -- 函数名称，如 concat
    qualified_name VARCHAR(1000),            -- 函数限定名称，如 default_db.concat
    category VARCHAR(100),                  -- 函数分类，如 string, numeric, date
    type VARCHAR(50),                       -- 函数类型，如 scalar, aggregate, window
    prototype TEXT,                         -- 函数原型，如 concat(str1, str2) -> string
    args JSONB,                             -- 参数定义，array<map<string,string>>，如 [{"name":"str1","type":"string"}]
    function_description TEXT,              -- 函数描述
    examples JSONB,                         -- 使用示例，array<map<string,string>>，如 [{"input":"concat('a','b')","output":"ab"}]
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_udf_function ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(category, '') || ' ' || COALESCE(prototype, '') || ' ' ||
    COALESCE(function_description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_udf_function_search_text_trgm
    ON t_semantic_udf_function USING gin (search_text gin_trgm_ops);

-- 9. 指标分组表 (Metric Groups)
-- 指标的分组/目录结构，支持层级树形组织
CREATE TABLE IF NOT EXISTS t_semantic_metric_group (
    group_id UUID CONSTRAINT pk_metric_group PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,               -- 分组名称
    qualified_name VARCHAR(500),              -- 限定名称，全局唯一标识
    group_code VARCHAR(255) NOT NULL CONSTRAINT uk_metric_group_group_code UNIQUE,  -- 分组编码，唯一标识
    group_path VARCHAR(500) NOT NULL,         -- 分组路径（如 /财务/收入/交易），支持层级检索
    parent_group_code VARCHAR(255),           -- 父分组编码，用于构建树形结构
    level INT,                                -- 层级深度（根为 0）
    domain VARCHAR(100),                      -- 所属业务域
    description TEXT,                          -- 分组描述
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_metric_group_parent
    ON t_semantic_metric_group (parent_group_code);
CREATE INDEX IF NOT EXISTS idx_metric_group_domain
    ON t_semantic_metric_group (domain) WHERE domain IS NOT NULL;

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_metric_group ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(group_code, '') || ' ' || COALESCE(group_path, '') || ' ' ||
    COALESCE(domain, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_metric_group_search_text_trgm
    ON t_semantic_metric_group USING gin (search_text gin_trgm_ops);

-- 10. 指标实例表 (Metric Instances)
-- 具体的指标实例，承载业务口径、计算逻辑与物化信息；合并原 semantic_metric 的定义字段
CREATE TABLE IF NOT EXISTS t_semantic_metric_instance (
    instance_id UUID CONSTRAINT pk_metric_instance PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,               -- 指标实例名称
    qualified_name VARCHAR(500),              -- 限定名称，全局唯一标识
    instance_code VARCHAR(255) NOT NULL CONSTRAINT uk_metric_instance_instance_code UNIQUE, -- 指标实例编码，唯一标识
    metric_name VARCHAR(255) NOT NULL,        -- 指标名称
    metric_code VARCHAR(255),                 -- 指标编码
    subject_entity VARCHAR(255) NOT NULL,     -- 主体实体（如 user, order）
    dimension_scope TEXT,                     -- 维度范围（如 city, category）
    grain VARCHAR(255),                       -- 粒度（如 day, month）
    scenario VARCHAR(255),                    -- 应用场景
    time_window VARCHAR(255),                 -- 时间窗口（如 7d, 30d, YTD）
    source_domain VARCHAR(255),               -- 来源域
    logical_expression TEXT,                  -- 逻辑表达式/计算口径
    aggregation_type VARCHAR(50),             -- 聚合类型（如 SUM, COUNT, AVG）
    is_pre_aggregated BOOLEAN DEFAULT FALSE,  -- 是否预聚合
    is_reaggregatable BOOLEAN DEFAULT TRUE,   -- 是否可再聚合
    default_filters TEXT,                     -- 默认过滤条件（JSON）
    calculation_formula TEXT,                 -- 给人类看的公式/伪代码计算逻辑（如 订单总额 - 退款总额）
    sql_snippet TEXT,                         -- 给 Agent 实际执行的 SQL 片段
    unit VARCHAR(50),                         -- 度量单位（如元，人，次）
    supported_grains TEXT[],                  -- 支持的下钻粒度（如 ["day", "city", "user"]）
    synonyms TEXT[],                          -- 同义词库
    description TEXT,                         -- 指标描述
    data_type VARCHAR(50),                    -- 数据类型（如 DECIMAL, BIGINT）
    metric_vector vector(768),                -- 指标语义向量（bge-base-zh-v1.5，768 维）
    metric_vector_m3 vector(1024),            -- 指标语义向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_metric_instance_subject
    ON t_semantic_metric_instance (subject_entity);
CREATE INDEX IF NOT EXISTS idx_metric_instance_metric_code
    ON t_semantic_metric_instance (metric_code) WHERE metric_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_metric_instance_domain
    ON t_semantic_metric_instance (source_domain) WHERE source_domain IS NOT NULL;

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_metric_instance ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(instance_code, '') || ' ' || COALESCE(metric_name, '') || ' ' ||
    COALESCE(metric_code, '') || ' ' ||
    COALESCE(subject_entity, '') || ' ' || COALESCE(dimension_scope, '') || ' ' ||
    COALESCE(grain, '') || ' ' || COALESCE(scenario, '') || ' ' ||
    COALESCE(time_window, '') || ' ' || COALESCE(source_domain, '') || ' ' ||
    COALESCE(logical_expression, '') || ' ' || COALESCE(aggregation_type, '') || ' ' ||
    COALESCE(description, '') || ' ' ||
    COALESCE(calculation_formula, '') || ' ' || COALESCE(sql_snippet, '') || ' ' ||
    COALESCE(unit, '') || ' ' || COALESCE(data_type, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_metric_instance_search_text_trgm
    ON t_semantic_metric_instance USING gin (search_text gin_trgm_ops);

ALTER TABLE t_semantic_metric_instance ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(instance_code, '') || ' ' || COALESCE(metric_name, '') || ' ' ||
    COALESCE(metric_code, '') || ' ' ||
    COALESCE(subject_entity, '') || ' ' || COALESCE(dimension_scope, '') || ' ' ||
    COALESCE(grain, '') || ' ' || COALESCE(scenario, '') || ' ' ||
    COALESCE(time_window, '') || ' ' || COALESCE(source_domain, '') || ' ' ||
    COALESCE(logical_expression, '') || ' ' || COALESCE(aggregation_type, '') || ' ' ||
    COALESCE(description, '') || ' ' ||
    COALESCE(calculation_formula, '') || ' ' || COALESCE(sql_snippet, '') || ' ' ||
    COALESCE(unit, '') || ' ' || COALESCE(data_type, '')
) STORED;
-- 全文召回：BM25（pg_search），chinese_lindera 中文分词 + 相关性排序
CREATE INDEX IF NOT EXISTS idx_metric_instance_bm25 ON t_semantic_metric_instance
    USING bm25 (instance_id, search_text_bm25)
    WITH (
        key_field = 'instance_id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- GIN 全文索引（tsvector + zhparser/simple），engine=gin 时使用
CREATE INDEX IF NOT EXISTS idx_metric_instance_search_text_gin ON t_semantic_metric_instance
    USING gin (to_tsvector(:'fts_config', search_text_bm25));

CREATE INDEX IF NOT EXISTS idx_metric_instance_metric_vec
    ON t_semantic_metric_instance USING hnsw (metric_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE metric_vector IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_metric_instance_metric_vec_m3
    ON t_semantic_metric_instance USING hnsw (metric_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE metric_vector_m3 IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_metric_instance_synonyms_gin
    ON t_semantic_metric_instance USING gin (synonyms)
    WHERE synonyms IS NOT NULL;

-- 11. Action 执行日志表 (Action Execution Logs)
-- 记录 action 的每次触发与执行状态，支持轻量审计与失败排障
CREATE TABLE IF NOT EXISTS t_semantic_action_execution_log (
    execution_id UUID CONSTRAINT pk_action_execution_log PRIMARY KEY DEFAULT uuid_generate_v4(),
    action_id UUID NOT NULL REFERENCES t_semantic_agent_action(action_id) ON DELETE CASCADE,
    source_type VARCHAR(50) CHECK (source_type IN ('Term', 'Entity', 'Metric')),
    source_id UUID,
    trigger_condition VARCHAR(100),
    status VARCHAR(20) NOT NULL CHECK (status IN ('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')),
    execution_channel VARCHAR(20) CHECK (execution_channel IN ('local', 'http')),
    is_fallback BOOLEAN DEFAULT FALSE,      -- 历史：local->http 回退；当前 Agent 仅 HTTP，恒为 false
    input_summary TEXT,                     -- 关键入参摘要（避免落全量敏感请求）
    result_summary TEXT,                    -- 关键出参摘要（轻量，便于审计与排障）
    error_message TEXT,                     -- 失败时错误信息
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    duration_ms BIGINT CHECK (duration_ms >= 0),
    record_status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_action_execution_log_action_time ON t_semantic_action_execution_log (action_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_action_execution_log_status_time ON t_semantic_action_execution_log (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_action_execution_log_source ON t_semantic_action_execution_log (source_type, source_id);

-- 9. 更新事件 Outbox 表 (Update Event Outbox)
-- 使用 Outbox 模式承接语义层/数据层更新事件，异步触发 on_update action。
CREATE TABLE IF NOT EXISTS t_semantic_update_event_outbox (
    event_id UUID CONSTRAINT pk_update_event_outbox PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_source VARCHAR(50) NOT NULL CHECK (event_source IN ('semantic_layer', 'business_data')),
    updates_json JSONB NOT NULL,
    payload_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    status VARCHAR(20) NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending', 'Processing', 'Retrying', 'Succeeded', 'Dead')),
    retry_count INT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    max_retries INT NOT NULL DEFAULT 5 CHECK (max_retries >= 1),
    available_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    locked_at TIMESTAMP WITH TIME ZONE,
    processing_node VARCHAR(120),
    last_error TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_update_event_outbox_pending ON t_semantic_update_event_outbox (status, available_at, created_at);
CREATE INDEX IF NOT EXISTS idx_update_event_outbox_created_at ON t_semantic_update_event_outbox (created_at DESC);


-- ============================================================================
-- 第二部分：【边表】业务关系路径 (Edge Tables)
-- ============================================================================

-- 1. 表关联路径 (TABLE_JOIN_RELATIONSHIP)
-- 描述数据表之间的关联关系，支持多对多、一对多、一对一等关联类型，即 Entity–TABLE_JOIN_RELATIONSHIP–Entity
CREATE TABLE IF NOT EXISTS t_semantic_edge_table_join_relationship (
    edge_id UUID CONSTRAINT pk_table_join_relationship PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,
    target_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,
    
    join_type VARCHAR(50) CHECK (join_type IN ('LEFT JOIN', 'INNER JOIN', 'FULL OUTER JOIN')), -- 推荐的连接类型
    join_condition TEXT NOT NULL,          -- 连接条件模板（如 {source}.buyer_id = {target}.user_id）。Agent 生成 SQL 时无需猜测关联字段，直接将别名套入模板即可
    cardinality VARCHAR(20) CHECK (cardinality IN ('1:1', '1:N', 'N:1', 'N:M')), -- 基数/数据行数关系。如果标识为 1:N 或 N:M，系统级 Prompt 需要警告 Agent：“在聚合计算前，必须先在子查询中对 target 表进行去重（GROUP BY），否则会导致 source 表的金额翻倍”。
    intent TEXT,                             -- 关联意图摘要
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_edge_tjr_source ON t_semantic_edge_table_join_relationship (source_entity_id);
CREATE INDEX IF NOT EXISTS idx_edge_tjr_target ON t_semantic_edge_table_join_relationship (target_entity_id);

-- 1c. SQL 使用列 (sql_use_column)
-- 对齐 type.json relationship sql_use_column：sql_process.used_columns <-> data_column.used_by_sqls；此处 data_column 映射为 data_column
CREATE TABLE IF NOT EXISTS t_semantic_edge_sql_use_column (
    edge_id UUID CONSTRAINT pk_sql_use_column PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_process_id UUID NOT NULL REFERENCES t_semantic_sql_process(process_id) ON DELETE CASCADE,
    target_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_edge_sql_use_colum_source_process_id_target_dime UNIQUE (source_process_id, target_dimension_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_sql_use_column_process ON t_semantic_edge_sql_use_column (source_process_id);
CREATE INDEX IF NOT EXISTS idx_edge_sql_use_column_dimension ON t_semantic_edge_sql_use_column (target_dimension_id);

-- 1d. 列级 JOIN 关联 (column_join_relationship)
-- 对齐 Atlas type column_join_relationship：两端为 data_column，此处映射为 data_column
CREATE TABLE IF NOT EXISTS t_semantic_edge_column_join_relationship (
    edge_id UUID CONSTRAINT pk_column_join_relationship PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,
    target_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,

    join_type VARCHAR(255),
    expression TEXT,
    intent TEXT,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_edge_column_join_src ON t_semantic_edge_column_join_relationship (source_dimension_id);
CREATE INDEX IF NOT EXISTS idx_edge_column_join_tgt ON t_semantic_edge_column_join_relationship (target_dimension_id);

-- 1d1. 列级外键关系 (column_foreign_key_relationship)
-- 对齐 YAML source_columns / target_columns（引用 dimensions[].id），支持复合外键
CREATE TABLE IF NOT EXISTS t_semantic_edge_column_foreign_key_relationship (
    edge_id UUID CONSTRAINT pk_column_foreign_key_relationship PRIMARY KEY DEFAULT uuid_generate_v4(),
    constraint_name VARCHAR(255) NOT NULL,
    source_column_ids UUID[] NOT NULL,
    target_column_ids UUID[] NOT NULL,
    source_entity_id UUID REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,
    target_entity_id UUID REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,
    description TEXT,
    on_delete_action VARCHAR(20) CHECK (on_delete_action IN ('CASCADE', 'RESTRICT', 'SET NULL', 'NO ACTION', 'SET DEFAULT')),
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CHECK (array_length(source_column_ids, 1) = array_length(target_column_ids, 1)),
    CONSTRAINT uk_edge_column_foreign_key_relation_constraint_name UNIQUE (constraint_name)
);
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_source_cols
    ON t_semantic_edge_column_foreign_key_relationship USING gin (source_column_ids);
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_target_cols
    ON t_semantic_edge_column_foreign_key_relationship USING gin (target_column_ids);
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_source_entity
    ON t_semantic_edge_column_foreign_key_relationship (source_entity_id);
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_target_entity
    ON t_semantic_edge_column_foreign_key_relationship (target_entity_id);

-- 3. 列归属映射 (TABLE_HAS_COLUMN)
-- 描述业务列表如何归属到数据表，即逻辑属性对应到哪些物理表，即Column-TABLE_HAS_COLUMN-Entity
CREATE TABLE IF NOT EXISTS t_semantic_edge_table_has_column (
    edge_id UUID CONSTRAINT pk_table_has_column PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,
    target_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,
    
    is_primary_source BOOLEAN DEFAULT TRUE,  -- 是否主来源。主来源的列可以作为该实体的唯一标识，辅助Agent在多维分析时快速锁定目标。
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_table_has_column_source_dimension_target_entity UNIQUE(source_dimension_id, target_entity_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_thc_target ON t_semantic_edge_table_has_column (target_entity_id);

-- 3b-edge. 列值关联 (COLUMN_HAS_VALUE)
-- 对齐 Atlas type.json column_has_value：data_column.values <-> data_column_value.column；COMPOSITION 关系
CREATE TABLE IF NOT EXISTS t_semantic_edge_column_has_value (
    edge_id UUID CONSTRAINT pk_column_has_value PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,
    target_value_id UUID NOT NULL REFERENCES t_semantic_data_column_value(value_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_column_has_value_source_dimension_target_value UNIQUE(source_dimension_id, target_value_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_column_has_value_dimension ON t_semantic_edge_column_has_value (source_dimension_id);
CREATE INDEX IF NOT EXISTS idx_edge_column_has_value_value ON t_semantic_edge_column_has_value (target_value_id);

-- 4. 术语属性拆解 (HAS_ATTRIBUTE)
-- 描述业务实体具有哪些业务列（逻辑属性），sematic_term通常通过has_attribute边表关联到data_column，即Term-HAS_ATTRIBUTE-Column
CREATE TABLE IF NOT EXISTS t_semantic_edge_has_attribute (
    edge_id UUID CONSTRAINT pk_has_attribute PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_term_id UUID NOT NULL REFERENCES t_semantic_term(term_id) ON DELETE CASCADE,
    target_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,
    
    weight INT DEFAULT 1,   -- 权重。用于衡量列对实体的重要性，辅助Agent在多维分析时快速锁定目标。
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_has_attribute_source_term_target_dimension UNIQUE(source_term_id, target_dimension_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_ha_target ON t_semantic_edge_has_attribute (target_dimension_id);

-- 4b. 术语关联 (HAS_TERM)
-- 描述一个业务术语如何关联到另一个业务术语，并附带可解释的中英文关系名与上下文列范围
CREATE TABLE IF NOT EXISTS t_semantic_edge_has_term (
    edge_id UUID CONSTRAINT pk_has_term PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_term_id UUID NOT NULL REFERENCES t_semantic_term(term_id) ON DELETE CASCADE,
    target_term_id UUID NOT NULL REFERENCES t_semantic_term(term_id) ON DELETE CASCADE,
    name_en VARCHAR(255),
    name_cn VARCHAR(255),
    source_dimension_ids UUID[] DEFAULT '{}'::UUID[],
    target_dimension_ids UUID[] DEFAULT '{}'::UUID[],
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CHECK (array_length(COALESCE(source_dimension_ids, '{}'::UUID[]), 1) IS NULL
        OR array_length(COALESCE(target_dimension_ids, '{}'::UUID[]), 1) IS NULL
        OR array_length(source_dimension_ids, 1) = array_length(target_dimension_ids, 1)),
    CONSTRAINT uk_has_term_source_term_target_term_en UNIQUE(source_term_id, target_term_id, name_en)
);
CREATE INDEX IF NOT EXISTS idx_edge_has_term_source_term ON t_semantic_edge_has_term (source_term_id);
CREATE INDEX IF NOT EXISTS idx_edge_has_term_target_term ON t_semantic_edge_has_term (target_term_id);
CREATE INDEX IF NOT EXISTS idx_edge_has_term_source_dims ON t_semantic_edge_has_term USING gin (source_dimension_ids);
CREATE INDEX IF NOT EXISTS idx_edge_has_term_target_dims ON t_semantic_edge_has_term USING gin (target_dimension_ids);

-- 5. 知识证据挂载 (DESCRIBES)
-- 描述知识证据如何挂载到业务实体、物理表实体、指标、列等。即Evidence-DESCRIBES-Entity/Metric/Column/Term
CREATE TABLE IF NOT EXISTS t_semantic_edge_describes (
    edge_id UUID CONSTRAINT pk_describes PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_evidence_id UUID NOT NULL REFERENCES t_semantic_knowledge_evidence(evidence_id) ON DELETE CASCADE,
    
    target_type VARCHAR(50) CHECK (target_type IN ('Entity', 'Metric', 'Dimension', 'Term')),
    target_id UUID NOT NULL, 
    
    relevance_score INT CHECK (relevance_score BETWEEN 0 AND 100), -- 相关性得分。用于衡量证据与目标的相关性，辅助Agent在多维分析时快速锁定目标。
    applied_scenario VARCHAR(100), -- 应用场景（如 Exception_Handling 异常处理, Definition 口径定义）。当用户询问“异常数据”时，优先召回此类文档。
    
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_describes_source_evidence_target_type_target UNIQUE(source_evidence_id, target_type, target_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_desc_target ON t_semantic_edge_describes (target_type, target_id);

-- 6. 安全治理拦截 (RESTRICTS)
-- 描述治理策略如何应用到业务实体/数据表/Action。即Policy-RESTRICTS-Entity/DataTable/Action
-- 支持三种绑定模式:
--   Object 模式: target_scope='Object', 填 target_type+target_id, 指向某条具体记录（如某张 data_table 行）
--   Table  模式: target_scope='Table',  填 target_table, 限制整张表的所有行（如所有 metric_instance）
--   Field  模式: target_scope='Field',  填 target_table+target_field, 限制表中特定列（如 data_column 的 phone 列）
-- 其中:
--   target_type   目标粗分类: Entity=data_table等实体表, Dimension=data_column等维度表, Action=agent_action
--   target_id     目标记录 UUID, 仅 Object 模式使用; OSI YAML 导入时由 target_ref（逻辑引用名）解析生成
--   target_scope  生效层级: Table=整表, Field=某列, Object=某条记录
--   target_table  目标表名, 取值为语义层注册的 29 张表之一; Table/Field 模式必填, Object 模式为 NULL
--   target_field  目标列名, 取值为 target_table 对应表的某列; 仅 Field 模式必填, 其余为 NULL
CREATE TABLE IF NOT EXISTS t_semantic_edge_restricts (
    edge_id UUID CONSTRAINT pk_restricts PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_policy_id UUID NOT NULL REFERENCES t_semantic_governance_policy(policy_id) ON DELETE CASCADE,

    target_type VARCHAR(50) CHECK (target_type IN ('Entity', 'Dimension', 'Action')), -- 目标粗分类（Object 模式使用）
    target_id UUID,                                                                     -- 目标记录 UUID（Object 模式使用, OSI 导入时由 target_ref 解析）
    target_scope VARCHAR(50) CHECK (target_scope IN ('Table', 'Field', 'Object')),       -- 生效层级: Table=整表, Field=某列, Object=某条记录
    target_table VARCHAR(100) CHECK (
        target_table IS NULL
        OR target_table IN (
            't_semantic_term', 't_semantic_data_table', 't_semantic_data_column', 't_semantic_data_column_value', 't_semantic_sql_process',
            't_semantic_knowledge_evidence', 't_semantic_governance_policy', 't_semantic_agent_action', 't_semantic_udf_function',
            't_semantic_metric_group', 't_semantic_metric_instance', 't_semantic_knowledge_evidence_edge', 't_semantic_action_execution_log',
            't_semantic_update_event_outbox', 't_semantic_edge_table_join_relationship', 't_semantic_edge_sql_use_column',
            't_semantic_edge_column_join_relationship', 't_semantic_edge_column_foreign_key_relationship',
            't_semantic_edge_table_has_column', 't_semantic_edge_column_has_value', 't_semantic_edge_has_attribute',
            't_semantic_edge_has_term', 't_semantic_edge_describes', 't_semantic_edge_restricts', 't_semantic_edge_triggers',
            't_semantic_edge_metric_instance_belongs_group', 't_semantic_edge_metric_instance_realized_in_table',
            't_semantic_edge_metric_instance_uses_column', 't_semantic_edge_metric_instance_derived_from_instance',
            't_semantic_instance_persistent_storage'
        )
    ),                                                                                  -- 目标表名（Table/Field 模式必填, 取值为语义层注册表之一）
    target_field VARCHAR(100),                                                          -- 目标列名（仅 Field 模式必填, 如 data_column 表的 phone 列）

    enforcement_level VARCHAR(50) CHECK (enforcement_level IN ('Strict', 'Warning', 'Audit_Only')), -- 执行级别（如 Strict 严格, Warning 警告, Audit_Only 仅审计）Strict 表示大模型生成的 SQL 必须无条件加上脱敏函数；Warning 表示仅在返回结果时向用户提示数据敏感。
    applied_roles TEXT[],    -- 生效角色群组。例如 ['external_agent', 'intern']，用于判断当前提问的用户是否命中该拦截规则。

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CHECK (
        target_scope IS NULL
        OR (target_scope = 'Table' AND target_table IS NOT NULL AND target_field IS NULL)
        OR (target_scope = 'Field' AND target_table IS NOT NULL AND target_field IS NOT NULL)
        OR (target_scope = 'Object' AND target_id IS NOT NULL)
    ),
    CONSTRAINT uk_restricts_source_policy_target_type_target UNIQUE(source_policy_id, target_type, target_id),
    CONSTRAINT uk_restricts_source_policy_target_scope_target_table UNIQUE(source_policy_id, target_scope, target_table, target_field, target_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_restricts_target ON t_semantic_edge_restricts (target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_edge_restricts_target_scope
    ON t_semantic_edge_restricts (target_scope, target_table, target_field);

-- 7. 系统动作触发 (TRIGGERS)
-- 定义特定实体，指标相关的action，即Entity/Metric-TRIGGERS-Action
CREATE TABLE IF NOT EXISTS t_semantic_edge_triggers (
    edge_id UUID CONSTRAINT pk_triggers PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_type VARCHAR(50) CHECK (source_type IN ('Term', 'Entity', 'Metric')),
    source_id UUID NOT NULL,
    
    target_action_id UUID NOT NULL REFERENCES t_semantic_agent_action(action_id) ON DELETE CASCADE,
    
    trigger_condition VARCHAR(100) NOT NULL, -- 触发事件（如on_access被查询时触发，on_update被修改时触发， on_timeout超时出发）
    is_blocking BOOLEAN DEFAULT FALSE,       -- 是否阻塞。True 表示触发后直接阻塞后续的SQL执行；False 表示触发后继续执行后续的SQL
    
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_triggers_source_type_source_target_action UNIQUE(source_type, source_id, target_action_id, trigger_condition)
);
CREATE INDEX IF NOT EXISTS idx_edge_triggers_source ON t_semantic_edge_triggers (source_type, source_id);

-- 8. 指标实例归属分组 (METRIC_INSTANCE_BELONGS_GROUP)
-- 描述指标实例归属到哪个指标分组，即 MetricGroup-BELONGS_GROUP-MetricInstance
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_belongs_group (
    edge_id UUID CONSTRAINT pk_mi_belongs_group PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_group_id UUID NOT NULL REFERENCES t_semantic_metric_group(group_id) ON DELETE CASCADE,
    target_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_metric_instance_belongs_group_source_group_target_instance UNIQUE(source_group_id, target_instance_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_belongs_group_group ON t_semantic_edge_metric_instance_belongs_group (source_group_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_belongs_group_instance ON t_semantic_edge_metric_instance_belongs_group (target_instance_id);

-- 9. 指标实例物化到数据表 (METRIC_INSTANCE_REALIZED_IN_TABLE)
-- 描述指标实例在哪些数据表中物化，即 MetricInstance-REALIZED_IN_TABLE-DataTable
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_realized_in_table (
    edge_id UUID CONSTRAINT pk_mi_realized_in_table PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,
    target_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_metric_instance_realized_in_table_source_instance_target_entity UNIQUE(source_instance_id, target_entity_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_realized_instance ON t_semantic_edge_metric_instance_realized_in_table (source_instance_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_realized_table ON t_semantic_edge_metric_instance_realized_in_table (target_entity_id);

-- 10. 指标实例使用数据列 (METRIC_INSTANCE_USES_COLUMN)
-- 描述指标实例使用了哪些数据列，即 MetricInstance-USES_COLUMN-DataColumn
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_uses_column (
    edge_id UUID CONSTRAINT pk_mi_uses_column PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,
    target_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_metric_instance_uses_column_source_instance_target_dimension UNIQUE(source_instance_id, target_dimension_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_uses_col_instance ON t_semantic_edge_metric_instance_uses_column (source_instance_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_uses_col_dimension ON t_semantic_edge_metric_instance_uses_column (target_dimension_id);

-- 11. 指标实例派生关系 (METRIC_INSTANCE_DERIVED_FROM_INSTANCE)
-- 描述指标实例间的派生/依赖关系，即 MetricInstance-DERIVED_FROM_INSTANCE-MetricInstance
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_derived_from_instance (
    edge_id UUID CONSTRAINT pk_mi_derived_from_instance PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,
    target_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_metric_instance_derived_from_instance_source_instance_target_instance UNIQUE(source_instance_id, target_instance_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_derived_source ON t_semantic_edge_metric_instance_derived_from_instance (source_instance_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_derived_target ON t_semantic_edge_metric_instance_derived_from_instance (target_instance_id);

-- ============================================================================
-- 列注释：将 DDL 内联 -- 注释写入 pg_description，
-- 供 SemanticLayerSchemaService 直接从 PG 元数据读取，无需依赖外部 SQL 文件。
-- ============================================================================

-- semantic_term
COMMENT ON COLUMN t_semantic_term.domain IS '所属业务域（如 Finance 财务, Growth 增长）。帮助 Agent 在多义词冲突时限定上下文范围。';
COMMENT ON COLUMN t_semantic_term.synonyms IS '同义词库。（如 ["GMV", "流水", "交易总额"]），扩展 Agent 的识别能力';

-- data_table
COMMENT ON COLUMN t_semantic_data_table.entity_type IS '物理类型（PhysicalTable 物理表, VirtualView 逻辑视图）';
COMMENT ON COLUMN t_semantic_data_table.schema_name IS '物理模式名（如 public, dwd）';
COMMENT ON COLUMN t_semantic_data_table.table_name IS '真实的物理表名';
COMMENT ON COLUMN t_semantic_data_table.table_name_en IS '英文/逻辑表名（与 type.json、ingestion、data_column.table_name_en 对齐）';
COMMENT ON COLUMN t_semantic_data_table.db_name_en IS '业务/逻辑库名英文（与 ingestion、data_column.db_name_en、AdvancedSearch 过滤一致）';
COMMENT ON COLUMN t_semantic_data_table.table_id IS '逻辑表标识（与 type.json data_table.table_id、列侧 table_id 对齐）';
COMMENT ON COLUMN t_semantic_data_table.layer IS '数仓分层（如 ODS, DWD, DWS），指导 Agent 优先选择加工好的高质量数据。';
COMMENT ON COLUMN t_semantic_data_table.column_descriptions IS '该实体表所有列名及其描述，格式：列名(类型): 描述；列名(类型): 描述；…';
COMMENT ON COLUMN t_semantic_data_table.qualified_name IS '全限定表名（如 postgres.public.orders_smoke）；供 AdvancedSearch table-relations-path 等解析';

-- data_column
COMMENT ON COLUMN t_semantic_data_column.qualified_name IS 'Atlas/Referenceable 列唯一限定名（与 ingestion qualifiedName 一致）';
COMMENT ON COLUMN t_semantic_data_column.is_primary_key IS '是否主键。让 Agent 知道该列是否可以作为 GROUP BY 或 DISTINCT 的依据';
COMMENT ON COLUMN t_semantic_data_column.column_value_profile IS '字段值分布摘要，如取值范围、TopN、空值率、异常值说明等';
COMMENT ON COLUMN t_semantic_data_column.db_name_en IS '业务库别名（英文），与 AdvancedSearch table-columns-info / column-value-info 两段式、三段式命名对齐';
COMMENT ON COLUMN t_semantic_data_column.table_name_en IS '物理表名（不含 schema），如 orders_smoke';
COMMENT ON COLUMN t_semantic_data_column.table_id IS '父 data_table 逻辑标识（对齐 Atlas type.json data_column.table_id）';
COMMENT ON COLUMN t_semantic_data_column.column_name_en IS '列名英文，如 order_id';
COMMENT ON COLUMN t_semantic_data_column.value_type IS '物理/逻辑类型（如 VARCHAR、bigint），供 Agent 引号与函数选择与过滤展示';

-- data_column_value
COMMENT ON COLUMN t_semantic_data_column_value.name IS '展示名（与 Atlas/Referenceable、ingestion name 对齐）';
COMMENT ON COLUMN t_semantic_data_column_value.qualified_name IS '全限定名（与 ingestion qualifiedName、column_has_value 端点解析一致）';
COMMENT ON COLUMN t_semantic_data_column_value.value IS '列取值（如 VIP、高价值客户）';
COMMENT ON COLUMN t_semantic_data_column_value.description IS '列取值描述（如 高价值客户）；语义检索与 description_vector 对齐 main-2 data_column_value_enum';
COMMENT ON COLUMN t_semantic_data_column_value.description_vector IS '描述文本嵌入（hybrid 文本列为 description）';
COMMENT ON COLUMN t_semantic_data_column_value.column_name_en IS '所属列名（英文），与 data_column.column_name_en 对齐';
COMMENT ON COLUMN t_semantic_data_column_value.table_name_en IS '所属物理表名（不含 schema），与 data_column.table_name_en 对齐';
COMMENT ON COLUMN t_semantic_data_column_value.db_name_en IS '业务库别名（英文），与 data_column.db_name_en 对齐';

-- sql_process
COMMENT ON COLUMN t_semantic_sql_process.sql_id IS '业务侧 SQL 标识，与 expression 均在 Atlas 上标为唯一';
COMMENT ON COLUMN t_semantic_sql_process.expression IS 'SQL 文本或规范化表达式';
COMMENT ON COLUMN t_semantic_sql_process.source_tables IS 'SQL 过程源表';
COMMENT ON COLUMN t_semantic_sql_process.target_table IS 'SQL 过程目标表';
COMMENT ON COLUMN t_semantic_sql_process.intent IS '可检索的意图摘要';
COMMENT ON COLUMN t_semantic_sql_process.query IS '自然语言问法或检索文本；可选建向量索引';
COMMENT ON COLUMN t_semantic_sql_process.query_vector IS '与 query 对应；须与 MetaVisor atlas.vector.embedding.dimensions 一致（默认 bge-base-zh = 768）';

-- knowledge_evidence
COMMENT ON COLUMN t_semantic_knowledge_evidence.name IS '证据标题（如：Q3财报营收对齐会议纪要）';
COMMENT ON COLUMN t_semantic_knowledge_evidence.raw_text IS '原始文本语料';
COMMENT ON COLUMN t_semantic_knowledge_evidence.confidence_score IS '置信度（0-100），用于召回排序';
COMMENT ON COLUMN t_semantic_knowledge_evidence.embedding IS '文本向量，使用 BAAI/bge-m3 (1024 维) 进行相似度检索';

-- knowledge_evidence_edge
COMMENT ON COLUMN t_semantic_knowledge_evidence_edge.name IS 'chunk name，便于排查与回表聚合';
COMMENT ON COLUMN t_semantic_knowledge_evidence_edge.edge_text IS '人类可读的短句（检索与展示）';
COMMENT ON COLUMN t_semantic_knowledge_evidence_edge.edge_embedding IS '与 chunk 相同：BAAI/bge-m3';

-- governance_policy
COMMENT ON COLUMN t_semantic_governance_policy.policy_level IS '策略生效层级（如 Row 行级, Column 列级, Table 表级）';
COMMENT ON COLUMN t_semantic_governance_policy.enforcement_type IS '执行类型（如 Masking 脱敏, Filtering 过滤, Block 屏蔽）';
COMMENT ON COLUMN t_semantic_governance_policy.rule_definition IS '具体的执行规则，大模型会根据这个定义（例如：将所有手机号替换为星号）去改写最终生成的sql';

-- agent_action
COMMENT ON COLUMN t_semantic_agent_action.execution_mode IS '执行模式（Sync 同步, Async 异步）告诉Agent调用后是应该原地等待结果，还是异步返回id';
COMMENT ON COLUMN t_semantic_agent_action.endpoint IS 'Action Service POST URL；执行 Sync 动作时应配置可达地址';
COMMENT ON COLUMN t_semantic_agent_action.parameters_schema IS '参数定义规范，作为Function Call的元数据';
COMMENT ON COLUMN t_semantic_agent_action.logic IS 'action的执行逻辑，如果不存在预制action，则需要根据这个logic生成action';

-- udf_function
COMMENT ON COLUMN t_semantic_udf_function.name IS '函数名称，如 concat';
COMMENT ON COLUMN t_semantic_udf_function.qualified_name IS '函数限定名称，如 default_db.concat';
COMMENT ON COLUMN t_semantic_udf_function.category IS '函数分类，如 string, numeric, date';
COMMENT ON COLUMN t_semantic_udf_function.type IS '函数类型，如 scalar, aggregate, window';
COMMENT ON COLUMN t_semantic_udf_function.prototype IS '函数原型，如 concat(str1, str2) -> string';
COMMENT ON COLUMN t_semantic_udf_function.args IS '参数定义，array<map<string,string>>，如 [{"name":"str1","type":"string"}]';
COMMENT ON COLUMN t_semantic_udf_function.function_description IS '函数描述';
COMMENT ON COLUMN t_semantic_udf_function.examples IS '使用示例，array<map<string,string>>，如 [{"input":"concat(''a'',''b'')","output":"ab"}]';

-- metric_group
COMMENT ON COLUMN t_semantic_metric_group.name IS '分组名称';
COMMENT ON COLUMN t_semantic_metric_group.qualified_name IS '限定名称，全局唯一标识';
COMMENT ON COLUMN t_semantic_metric_group.group_code IS '分组编码，唯一标识';
COMMENT ON COLUMN t_semantic_metric_group.group_path IS '分组路径（如 /财务/收入/交易），支持层级检索';
COMMENT ON COLUMN t_semantic_metric_group.parent_group_code IS '父分组编码，用于构建树形结构';
COMMENT ON COLUMN t_semantic_metric_group.level IS '层级深度（根为 0）';
COMMENT ON COLUMN t_semantic_metric_group.domain IS '所属业务域';
COMMENT ON COLUMN t_semantic_metric_group.description IS '分组描述';

-- metric_instance
COMMENT ON COLUMN t_semantic_metric_instance.name IS '指标实例名称';
COMMENT ON COLUMN t_semantic_metric_instance.qualified_name IS '限定名称，全局唯一标识';
COMMENT ON COLUMN t_semantic_metric_instance.instance_code IS '指标实例编码，唯一标识';
COMMENT ON COLUMN t_semantic_metric_instance.metric_name IS '指标名称';
COMMENT ON COLUMN t_semantic_metric_instance.metric_code IS '指标编码';
COMMENT ON COLUMN t_semantic_metric_instance.subject_entity IS '主体实体（如 user, order）';
COMMENT ON COLUMN t_semantic_metric_instance.dimension_scope IS '维度范围（如 city, category）';
COMMENT ON COLUMN t_semantic_metric_instance.grain IS '粒度（如 day, month）';
COMMENT ON COLUMN t_semantic_metric_instance.scenario IS '应用场景';
COMMENT ON COLUMN t_semantic_metric_instance.time_window IS '时间窗口（如 7d, 30d, YTD）';
COMMENT ON COLUMN t_semantic_metric_instance.source_domain IS '来源域';
COMMENT ON COLUMN t_semantic_metric_instance.logical_expression IS '逻辑表达式/计算口径';
COMMENT ON COLUMN t_semantic_metric_instance.aggregation_type IS '聚合类型（如 SUM, COUNT, AVG）';
COMMENT ON COLUMN t_semantic_metric_instance.is_pre_aggregated IS '是否预聚合';
COMMENT ON COLUMN t_semantic_metric_instance.is_reaggregatable IS '是否可再聚合';
COMMENT ON COLUMN t_semantic_metric_instance.default_filters IS '默认过滤条件（JSON）';
COMMENT ON COLUMN t_semantic_metric_instance.calculation_formula IS '给人类看的公式/伪代码计算逻辑（如 订单总额 - 退款总额）';
COMMENT ON COLUMN t_semantic_metric_instance.sql_snippet IS '给 Agent 实际执行的 SQL 片段';
COMMENT ON COLUMN t_semantic_metric_instance.unit IS '度量单位（如元，人，次）';
COMMENT ON COLUMN t_semantic_metric_instance.supported_grains IS '支持的下钻粒度（如 ["day", "city", "user"]）';
COMMENT ON COLUMN t_semantic_metric_instance.synonyms IS '同义词库';
COMMENT ON COLUMN t_semantic_metric_instance.description IS '指标描述';
COMMENT ON COLUMN t_semantic_metric_instance.data_type IS '数据类型（如 DECIMAL, BIGINT）';

-- action_execution_log
COMMENT ON COLUMN t_semantic_action_execution_log.is_fallback IS '历史：local->http 回退；当前 Agent 仅 HTTP，恒为 false';
COMMENT ON COLUMN t_semantic_action_execution_log.input_summary IS '关键入参摘要（避免落全量敏感请求）';
COMMENT ON COLUMN t_semantic_action_execution_log.result_summary IS '关键出参摘要（轻量，便于审计与排障）';
COMMENT ON COLUMN t_semantic_action_execution_log.error_message IS '失败时错误信息';

-- edge_table_join_relationship
COMMENT ON COLUMN t_semantic_edge_table_join_relationship.join_type IS '推荐的连接类型';
COMMENT ON COLUMN t_semantic_edge_table_join_relationship.join_condition IS '连接条件模板（如 {source}.buyer_id = {target}.user_id）。Agent 生成 SQL 时无需猜测关联字段，直接将别名套入模板即可';
COMMENT ON COLUMN t_semantic_edge_table_join_relationship.cardinality IS '基数/数据行数关系。如果标识为 1:N 或 N:M，系统级 Prompt 需要警告 Agent："在聚合计算前，必须先在子查询中对 target 表进行去重（GROUP BY），否则会导致 source 表的金额翻倍"。';
COMMENT ON COLUMN t_semantic_edge_table_join_relationship.intent IS '关联意图摘要';

-- edge_table_has_column
COMMENT ON COLUMN t_semantic_edge_table_has_column.is_primary_source IS '是否主来源。主来源的列可以作为该实体的唯一标识，辅助Agent在多维分析时快速锁定目标。';

-- edge_describes
COMMENT ON COLUMN t_semantic_edge_describes.relevance_score IS '相关性得分。用于衡量证据与目标的相关性，辅助Agent在多维分析时快速锁定目标。';
COMMENT ON COLUMN t_semantic_edge_describes.applied_scenario IS '应用场景（如 Exception_Handling 异常处理, Definition 口径定义）。当用户询问"异常数据"时，优先召回此类文档。';

-- edge_restricts
COMMENT ON COLUMN t_semantic_edge_restricts.enforcement_level IS '执行级别（如 Strict 严格, Warning 警告, Audit_Only 仅审计）Strict 表示大模型生成的 SQL 必须无条件加上脱敏函数；Warning 表示仅在返回结果时向用户提示数据敏感。';
COMMENT ON COLUMN t_semantic_edge_restricts.applied_roles IS '生效角色群组。例如 [''external_agent'', ''intern'']，用于判断当前提问的用户是否命中该拦截规则。';

-- edge_triggers
COMMENT ON COLUMN t_semantic_edge_triggers.trigger_condition IS '触发事件（如on_access被查询时触发，on_update被修改时触发， on_timeout超时出发）';
COMMENT ON COLUMN t_semantic_edge_triggers.is_blocking IS '是否阻塞。True 表示触发后直接阻塞后续的SQL执行；False 表示触发后继续执行后续的SQL';




-- ============================================================================
-- 第三部分：【Ontology 模块 扩展表】
--
-- 以下 8 张表为 Ontology 模块 层新增的扩展表，用于在语义层之上构建场景本体。
-- 语义层表（29 张）保持不动，作为企业全量语义资产的权威存储；
-- Ontology 扩展表引用语义层实体，仅存储语义层缺少的 Ontology 特有信息。
--
-- 主键命名约定：所有表的主键统一为 id UUID DEFAULT uuid_generate_v4()，
-- 与语义层已有表风格一致。
-- ============================================================================

-- ============================================================================
-- 1. ontology_definition（本体定义表）
-- 面向特定场景的完整本体。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_definition (
    id UUID CONSTRAINT pk_ontology_definition PRIMARY KEY DEFAULT uuid_generate_v4(),
    api_name VARCHAR(255) NOT NULL CONSTRAINT uk_ontology_definition_api_name UNIQUE,
    display_name VARCHAR(255),
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ontology_def_api_name ON t_semantic_ontology_definition (api_name);

-- 本体检索基建（06 报告 FR-1.1）：双模型向量列 + BM25 生成列 + HNSW/BM25 索引（三表同构）
ALTER TABLE t_semantic_ontology_definition ADD COLUMN IF NOT EXISTS search_vector vector(768);
ALTER TABLE t_semantic_ontology_definition ADD COLUMN IF NOT EXISTS search_vector_m3 vector(1024);
CREATE INDEX IF NOT EXISTS idx_ontology_def_search_vec
    ON t_semantic_ontology_definition USING hnsw (search_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_ontology_def_search_vec_m3
    ON t_semantic_ontology_definition USING hnsw (search_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE search_vector_m3 IS NOT NULL;
ALTER TABLE t_semantic_ontology_definition ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(api_name, '') || ' ' || COALESCE(display_name, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_ontology_def_bm25 ON t_semantic_ontology_definition
    USING bm25 (id, search_text_bm25)
    WITH (
        key_field = 'id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- ============================================================================
-- 2. entity_type（实体类型定义表）
-- EntityType 的独立定义表，api_name 为本体层实体唯一标识。
-- 通过 semantic_term.related_entity_type_id 反向关联，维持 N:1 关系
--（多个 semantic_term 可关联到同一个 entity_type）。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_entity_type (
    id UUID CONSTRAINT pk_entity_type PRIMARY KEY DEFAULT uuid_generate_v4(),
    api_name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    description TEXT,
    primary_property_names TEXT[] DEFAULT '{}'::TEXT[],
    title_property_names TEXT[] DEFAULT '{}'::TEXT[],
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_et_api_name ON t_semantic_entity_type (api_name);

-- 本体检索基建（06 报告 FR-1.1）：双模型向量列 + BM25 生成列 + HNSW/BM25 索引（三表同构）
ALTER TABLE t_semantic_entity_type ADD COLUMN IF NOT EXISTS search_vector vector(768);
ALTER TABLE t_semantic_entity_type ADD COLUMN IF NOT EXISTS search_vector_m3 vector(1024);
CREATE INDEX IF NOT EXISTS idx_et_search_vec
    ON t_semantic_entity_type USING hnsw (search_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_et_search_vec_m3
    ON t_semantic_entity_type USING hnsw (search_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE search_vector_m3 IS NOT NULL;
ALTER TABLE t_semantic_entity_type ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(api_name, '') || ' ' || COALESCE(display_name, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_et_bm25 ON t_semantic_entity_type
    USING bm25 (id, search_text_bm25)
    WITH (
        key_field = 'id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- ============================================================================
-- 3. relation_type（关系类型定义表）
-- RelationType 的独立定义，引用 entity_type（source/target），
-- 只存储语义层缺少的字段。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_relation_type (
    id UUID CONSTRAINT pk_relation_type PRIMARY KEY DEFAULT uuid_generate_v4(),
    api_name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    description TEXT,
    cardinality VARCHAR(20),
    source_entity_type_id UUID NOT NULL,
    target_entity_type_id UUID NOT NULL,
    source_properties_for_join TEXT[] DEFAULT '{}'::TEXT[],
    target_properties_for_join TEXT[] DEFAULT '{}'::TEXT[],
    primary_property_names TEXT[] DEFAULT '{}'::TEXT[],
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (source_entity_type_id)
        REFERENCES t_semantic_entity_type(id) ON DELETE RESTRICT,
    FOREIGN KEY (target_entity_type_id)
        REFERENCES t_semantic_entity_type(id) ON DELETE RESTRICT,
    CHECK (cardinality IS NULL OR cardinality IN (
        'ONE_TO_ONE', 'ONE_TO_MANY', 'MANY_TO_ONE', 'MANY_TO_MANY'))
);

CREATE INDEX IF NOT EXISTS idx_rt_api_name ON t_semantic_relation_type (api_name);
CREATE INDEX IF NOT EXISTS idx_rt_source_entity ON t_semantic_relation_type (source_entity_type_id);
CREATE INDEX IF NOT EXISTS idx_rt_target_entity ON t_semantic_relation_type (target_entity_type_id);

-- 本体检索基建（06 报告 FR-1.1）：双模型向量列 + BM25 生成列 + HNSW/BM25 索引（三表同构）
ALTER TABLE t_semantic_relation_type ADD COLUMN IF NOT EXISTS search_vector vector(768);
ALTER TABLE t_semantic_relation_type ADD COLUMN IF NOT EXISTS search_vector_m3 vector(1024);
CREATE INDEX IF NOT EXISTS idx_rt_search_vec
    ON t_semantic_relation_type USING hnsw (search_vector vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_rt_search_vec_m3
    ON t_semantic_relation_type USING hnsw (search_vector_m3 vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE search_vector_m3 IS NOT NULL;
ALTER TABLE t_semantic_relation_type ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(api_name, '') || ' ' || COALESCE(display_name, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_rt_bm25 ON t_semantic_relation_type
    USING bm25 (id, search_text_bm25)
    WITH (
        key_field = 'id',
        text_fields = '{"search_text_bm25": {"tokenizer": {"type": "chinese_lindera"}}}'
    );

-- ============================================================================
-- 4. ontology_property_binding（属性绑定表）
-- 场景级属性覆盖：同一语义层属性在不同本体中可有不同的 API 名、展示名。
-- owner_type = 'EntityType' 或 'RelationType'，owner_id 引用 entity_type/relation_type 的 id。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_property_binding (
    id UUID CONSTRAINT pk_ontology_property_binding PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_type VARCHAR(32) NOT NULL,
    owner_id UUID NOT NULL,
    property_api_name VARCHAR(255) NOT NULL,
    dimension_id UUID REFERENCES t_semantic_data_column(dimension_id) ON DELETE RESTRICT,
    display_name VARCHAR(255),
    alias_table_name VARCHAR(255),
    column_name VARCHAR(255),
    data_type VARCHAR(50),
    property_description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_ontology_property_binding_owner_type_owner_property_api UNIQUE(owner_type, owner_id, property_api_name)
);

CREATE INDEX IF NOT EXISTS idx_prop_binding_owner ON t_semantic_ontology_property_binding (owner_type, owner_id);
CREATE INDEX IF NOT EXISTS idx_prop_binding_dimension ON t_semantic_ontology_property_binding (dimension_id);

-- ============================================================================
-- 5. database_info（数据库连接信息表）
-- 全局数据库连接配置，独立于本体定义。一个连接可被多个本体和多个实体类型共用。
-- data_source_name: 数据源名称，作为唯一标识符，用于在多个本体间共享连接配置。
-- 安全说明（待实现）：
--   connection_string 包含用户名/密码等敏感信息，后续应使用 pgcrypto 列级加密
--   或接入 Vault 等密钥管理系统。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_database_info (
    id UUID CONSTRAINT pk_database_info PRIMARY KEY DEFAULT uuid_generate_v4(),
    data_source_name VARCHAR(255) NOT NULL CONSTRAINT uk_database_info_data_source_name UNIQUE,
    data_source_type VARCHAR(50) NOT NULL,
    connection_string TEXT,  -- Changed from NOT NULL to nullable to preserve distinction between null and empty string
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_database_info_name ON t_semantic_database_info (data_source_name);

-- 已有库升级（新增 data_source_name）：
--   ALTER TABLE t_semantic_database_info ADD COLUMN IF NOT EXISTS data_source_name VARCHAR(255);
--   -- 为历史数据填充默认名称（可选）
--   UPDATE database_info SET data_source_name = 'ds_' || id::text WHERE data_source_name IS NULL;
--   -- 添加 NOT NULL 约束
--   ALTER TABLE t_semantic_database_info ALTER COLUMN data_source_name SET NOT NULL;
--   -- 添加唯一约束
--   ALTER TABLE t_semantic_database_info ADD CONSTRAINT uk_database_info_name UNIQUE (data_source_name);
--   -- 创建索引
--   CREATE INDEX IF NOT EXISTS idx_database_info_name ON t_semantic_database_info (data_source_name);

-- ============================================================================
-- 6. ontology_data_source_binding（数据源绑定表）
-- 实体/关系类型 → 物理数据表的绑定，通过 database_id 引用连接配置。
-- 将连接信息与绑定信息分离，便于对不同级别信息做不同安全管控。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_data_source_binding (
    id UUID CONSTRAINT pk_ontology_data_source_binding PRIMARY KEY DEFAULT uuid_generate_v4(),
    api_name VARCHAR(255) NOT NULL,
    database_id UUID NOT NULL REFERENCES t_semantic_database_info(id) ON DELETE RESTRICT,
    owner_type VARCHAR(32),
    owner_id UUID,
    data_table_id UUID REFERENCES t_semantic_data_table(entity_id) ON DELETE RESTRICT,
    table_name VARCHAR(500),
    primary_key_columns TEXT[] DEFAULT '{}',
    source_entity_type_primary_keys TEXT[] DEFAULT '{}',
    target_entity_type_primary_keys TEXT[] DEFAULT '{}',
    condition TEXT,
    partition_field VARCHAR(255),
    period_type VARCHAR(20) CHECK (period_type IS NULL OR period_type IN ('full', 'incremental')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 已有库升级（新增 partition_field / period_type）：
--   ALTER TABLE t_semantic_ontology_data_source_binding ADD COLUMN IF NOT EXISTS partition_field VARCHAR(255);
--   ALTER TABLE t_semantic_ontology_data_source_binding ADD COLUMN IF NOT EXISTS period_type VARCHAR(20);
--   ALTER TABLE t_semantic_ontology_data_source_binding ADD CONSTRAINT ck_binding_period_type
--       CHECK (period_type IS NULL OR period_type IN ('full', 'incremental'));

CREATE INDEX IF NOT EXISTS idx_binding_database ON t_semantic_ontology_data_source_binding (database_id);
CREATE INDEX IF NOT EXISTS idx_binding_owner ON t_semantic_ontology_data_source_binding (owner_type, owner_id);
CREATE INDEX IF NOT EXISTS idx_binding_table ON t_semantic_ontology_data_source_binding (data_table_id);

-- ============================================================================
-- 7. ontology_own_entity_type（本体-实体类型关联表）
-- 关联表：记录哪个本体引用了哪个实体类型，支持来源追踪。
-- source_type: 'ontology' 表示本体自建或 JSON 上传创建，'domain' 表示从 Domain 导入
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_own_entity_type (
    ontology_id UUID NOT NULL,
    entity_type_id UUID NOT NULL,
    source_type VARCHAR(20) NOT NULL DEFAULT 'ontology',
    domain_id UUID,
    domain_name VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_ontology_own_entity_type PRIMARY KEY (ontology_id, entity_type_id),
    FOREIGN KEY (ontology_id)
        REFERENCES t_semantic_ontology_definition(id) ON DELETE CASCADE,
    FOREIGN KEY (entity_type_id)
        REFERENCES t_semantic_entity_type(id) ON DELETE RESTRICT,
    CONSTRAINT ck_own_et_source_type CHECK (source_type IN ('ontology', 'domain'))
);

CREATE INDEX IF NOT EXISTS idx_own_et_entity ON t_semantic_ontology_own_entity_type (entity_type_id);
CREATE INDEX IF NOT EXISTS idx_own_et_source_type ON t_semantic_ontology_own_entity_type (source_type);
CREATE INDEX IF NOT EXISTS idx_own_et_domain_id ON t_semantic_ontology_own_entity_type (domain_id);
CREATE INDEX IF NOT EXISTS idx_own_et_domain_name ON t_semantic_ontology_own_entity_type (domain_name);

-- ============================================================================
-- 8. ontology_own_relation_type（本体-关系类型关联表）
-- 纯关联表：记录哪个本体引用了哪个关系类型。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_own_relation_type (
    ontology_id UUID NOT NULL,
    relation_type_id UUID NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_ontology_own_relation_type PRIMARY KEY (ontology_id, relation_type_id),
    FOREIGN KEY (ontology_id)
        REFERENCES t_semantic_ontology_definition(id) ON DELETE CASCADE,
    FOREIGN KEY (relation_type_id)
        REFERENCES t_semantic_relation_type(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_own_rt_relation ON t_semantic_ontology_own_relation_type (relation_type_id);

-- ============================================================================
-- 9. ontology_domain（域管理表）
-- 域是公共 EntityType 的容器，支持多层分组树管理。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_domain (
    id UUID CONSTRAINT pk_ontology_domain PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_ontology_domain_name UNIQUE (name)
);

CREATE INDEX IF NOT EXISTS idx_ontology_domain_name ON t_semantic_ontology_domain (name);

-- ============================================================================
-- 10. ontology_domain_group（域分组表）
-- 域内分组树，最大深度 5 层。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_domain_group (
    id UUID CONSTRAINT pk_ontology_domain_group PRIMARY KEY DEFAULT uuid_generate_v4(),
    domain_id UUID NOT NULL REFERENCES t_semantic_ontology_domain(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    parent_group_id UUID REFERENCES t_semantic_ontology_domain_group(id) ON DELETE CASCADE,
    level INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_ontology_domain_group_level CHECK (level >= 1 AND level <= 5),
    CONSTRAINT uk_domain_group_sibling_name UNIQUE (domain_id, parent_group_id, name)
);

CREATE INDEX IF NOT EXISTS idx_domain_group_domain ON t_semantic_ontology_domain_group (domain_id);
CREATE INDEX IF NOT EXISTS idx_domain_group_parent ON t_semantic_ontology_domain_group (parent_group_id);

-- 根分组同名唯一约束（parent_group_id IS NULL 时）
CREATE UNIQUE INDEX IF NOT EXISTS uk_domain_root_group_name
    ON t_semantic_ontology_domain_group (domain_id, name)
    WHERE parent_group_id IS NULL;

-- ============================================================================
-- 11. ontology_domain_own_entity_type（域-EntityType 关联表）
-- 记录域/分组与 EntityType 的关联关系。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_domain_own_entity_type (
    id UUID CONSTRAINT pk_ontology_domain_own_entity_type PRIMARY KEY DEFAULT uuid_generate_v4(),
    domain_id UUID NOT NULL REFERENCES t_semantic_ontology_domain(id) ON DELETE CASCADE,
    group_id UUID NOT NULL REFERENCES t_semantic_ontology_domain_group(id) ON DELETE CASCADE,
    entity_type_id UUID NOT NULL REFERENCES t_semantic_entity_type(id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_domain_entity_type UNIQUE (domain_id, entity_type_id)
);

CREATE INDEX IF NOT EXISTS idx_domain_own_et_domain ON t_semantic_ontology_domain_own_entity_type (domain_id);
CREATE INDEX IF NOT EXISTS idx_domain_own_et_group ON t_semantic_ontology_domain_own_entity_type (group_id);
CREATE INDEX IF NOT EXISTS idx_domain_own_et_entity ON t_semantic_ontology_domain_own_entity_type (entity_type_id);

-- ============================================================================
-- 12. Ontology 模块 后置关联约束
-- semantic_term.related_entity_type_id → entity_type(id)
-- 必须在 entity_type 创建后才能添加（前向引用不允许）
-- ============================================================================
-- 用 DO $$ IF NOT EXISTS 包裹：ADD CONSTRAINT 无 IF NOT EXISTS（PG/GV 同），
-- 包裹后重复执行幂等（约束已存在则跳过）。
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_semantic_term_entity_type') THEN
        ALTER TABLE t_semantic_term
            ADD CONSTRAINT fk_semantic_term_entity_type
            FOREIGN KEY (related_entity_type_id) REFERENCES t_semantic_entity_type(id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_semantic_term_entity_type ON t_semantic_term (related_entity_type_id);

-- ============================================================================
-- 13. t_semantic_instance_persistent_storage（实例化持久化存储配置表）
-- 存储 Ontology 场景的图存储连接配置（如 NebulaGraph），按 scene_name 唯一。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_instance_persistent_storage (
    api_name VARCHAR(255) CONSTRAINT pk_instance_persistent_storage PRIMARY KEY,
    storage_configs TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- 扩展部分： t_semantic_ingestion_trace（ingestion job 状态管理表）
-- 由外部平台传入的 trace_id 标识一次 ingestion job；status 为 updating/normal/failed。
-- 超时判定基准为 created_at。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ingestion_trace (
    trace_id            VARCHAR(128) NOT NULL,
    ingestion_scenario  VARCHAR(50)  NOT NULL,
    status              VARCHAR(20)  NOT NULL
                        CHECK (status IN ('updating', 'normal', 'failed')),
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_ingestion_trace PRIMARY KEY (trace_id)
);

CREATE INDEX IF NOT EXISTS idx_ingestion_trace_status_created
    ON t_semantic_ingestion_trace (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ingestion_trace_scenario_created
    ON t_semantic_ingestion_trace (ingestion_scenario, created_at DESC);
