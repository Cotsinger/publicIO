-- ============================================================================
-- GaussVector 版整库建表脚本（对应 PostgreSQL 版 create_semantic_layer.sql）
--
-- 目标数据库：库须由运维/平台提前建好（本脚本不建库）。public 占位符由
--   JDBC 路径的 Java 层（String.replace）替换为配置的 schema 名；gsql 手动执行时
--   先 sed 替换。schema 名从 semantic_service.db.schema-name 读取（默认 public）。
--   见 docs/design/jdbc-schema-init-unification-design.md。
--
-- 执行示例（gsql，库已提前建好，先替换 public）：
--   gsql -p 5678 -d <dbname> -r -v ON_ERROR_STOP=1 -f create_semantic_layer_gaussvector.sql
--
-- 手动重建（清空已有数据）：先 DROP SCHEMA <name> CASCADE 再执行本脚本；
--   或直接使用服务启动参数 -c（语义相同）。
--
-- 与 PostgreSQL 版的差异（详见文末"与 PostgreSQL 脚本的差异说明"）：
--   1. 去掉 CREATE EXTENSION（向量/BM25/UUID 均为 GaussVector 内置能力）
--   2. 向量列 vector(N) → floatvector(N) NOT NULL（GaussVector 列级不允许 NULL）
--   3. HNSW 索引 → GsDiskANN（参数 graph_degree/num_parallels/enable_pq/subgraph_count；
--      冷启动 enable_pq=false，不传 pq_nseg/pq_nclus，二者仅 enable_pq=true 时生效）
--   4. UUID DEFAULT uuid_generate_v4() → DEFAULT uuid()::uuid（GaussVector 无 uuid_generate_v4()，
--      用内置 uuid()（返回 varchar，须 ::uuid cast）作列 DEFAULT；uuid() 返回 V7 时间戳排序 UUID
--      （前 48 位为毫秒时间戳，随时间单调递增；非 PG 的 V4 随机 UUID），详见
--      docs/design/gaussvector-backend-design.md §9.2）
--   5. ParadeDB BM25 多列索引 → GaussVector 原生 BM25 单列索引（### 算子，
--      BM25 仅支持单列，故对每个文本列单独建索引；内置 simple_cn_segmentation 中文分词）
--   6. pg_trgm 索引（gin_trgm_ops）→ 全部移除（GaussVector 不支持 pg_trgm，
--      模糊匹配降级为 ILIKE 粗召回 + 应用层精排，见设计文档 §6）
--   7. gin(text 表达式) 索引 → 移除（GaussVector 对 text 表达式无默认 gin opclass）
--   8. 含 GIN 索引（tsvector/jsonb/数组）的表加 WITH (storage_type=astore)
--      （GaussVector 默认 Ustore 不支持 GIN，须 astore，见设计文档 D9）
--   9. tsvector 生成列 regconfig 由 'simple' 保留（GaussVector 无 'chinese' regconfig，
--      知识图谱 tsvectorRecall 传 'simple'/'ngram'，见设计文档 M3）
--
-- 依据：docs/design/gaussvector-backend-design.md v7.0 + docs/test/gaussvector-backend-test-report.md
-- 验证：GaussVector 103.0.0 build c8f60daf，gsql 实测（2026-07-16）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- [库前提] 数据库须由运维/平台提前建好（本脚本不建库）。
--   - JDBC 路径：服务启动时借主库 DataSource 连接执行本脚本（幂等建表），
--     先探活（库不存在/不可连即启动失败）。
--   - 库名取自 semantic_service.db.url 末段，库提前建好且可连是运维前提。
--   - schema 统一由 Java 侧（check-then-create）负责；本脚本内 DO 块幂等建 schema
--     仅对 gsql 手动路径有益（public 需先替换）。
--   - 本脚本无任何 DROP 语句，幂等完全靠 IF NOT EXISTS，可安全重复执行。
-- ----------------------------------------------------------------------------
-- ============================================================================
-- [Schema 初始化] 业务表/函数建在 public schema 下，而非 public
-- public 占位符由 JDBC 路径的 Java 层 String.replace 替换（gsql 手动路径需先 sed）。
-- SET search_path 为会话级：gsql -f 与 JDBC 单 Connection 逐条 execute 均持续生效，
-- 后续所有 CREATE TABLE/FUNCTION（不带 schema 前缀）自动落到 public。
-- pg_catalog 兜底系统函数解析（uuid() 等）——CREATE 只会落到
-- search_path 第一个 schema（public），不会建到 pg_catalog。
-- GaussVector 不支持 PG 的 "CREATE SCHEMA IF NOT EXISTS" 语法（实测报
-- "syntax error at or near 'NOT EXISTS'"），故用 DO 块查 pg_namespace 幂等建 schema：
-- schema 已存在则跳过 CREATE，重复执行不报错。
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'public') THEN
        CREATE SCHEMA public;
    END IF;
END $$;
SET search_path = public, pg_catalog;

-- ============================================================================
-- [环境准备] enable_vectordb GUC（向量能力开关，GaussVector 默认开启）
-- 启动校验脚本会探测此 GUC；此处仅作说明，无需 ALTER SYSTEM。
-- ============================================================================

-- ============================================================================
-- Schema 命名空间约定
--
-- 本文件的表、索引和 uuid_arr_to_text_arr 函数故意使用未限定
-- schema 的名称，落库位置由执行方的 search_path 决定：
--   - JDBC（服务启动/多场景）：SET search_path TO <target>, <shared>, pg_catalog
--   - gsql 手动执行：本文件内 SET search_path = public, pg_catalog
-- 多场景模式下 shared extension schema 不得存放语义表。
-- ============================================================================

-- ============================================================================
-- [辅助函数] uuid[] → text[] 的 IMMUTABLE 包装函数
-- 用途：GaussVector 的 GIN 不支持 uuid[] 默认 opclass（实测 "data type uuid[] has no
--   default operator class for access method gin"，而 text[] 支持）。对 UUID 数组列
--   建表达式 GIN 索引时，直接 `col::text[]` cast 在索引表达式/生成列中被判为非 IMMUTABLE
--   （openGauss 内核未把 uuid↔text cast 标 immutable），故用 IMMUTABLE SQL 函数包装，
--   在 edge_column_foreign_key_relationship / edge_has_term 的 UUID[] 列上建表达式 GIN 索引。
-- 等价查询：`'<uuid>' = ANY(uuid_arr_to_text_arr(col))`（与 PG `= ANY(col)` 语义一致，
--   仅多一层函数调用，索引表达式中查询须用相同函数表达式才能走索引）。
-- ============================================================================
CREATE OR REPLACE FUNCTION uuid_arr_to_text_arr(uuids UUID[]) RETURNS TEXT[]
IMMUTABLE LANGUAGE sql AS $$
    SELECT array_agg(u::text) FROM unnest($1) u;
$$;

-- ============================================================================
-- [零向量默认值] floatvector 列不允许 NULL，建表须给 DEFAULT。为避免在 DDL 中
--   写 768/1024 个字面量 0（单行约 1.6~2.2 KB，属纯 diff 噪声），统一用
--   ('[' || repeat('0,', N-1) || '0]')::floatvector(N) 生成等值零向量；repeat 为
--   不可变函数，默认值在插入时求值，与字面量写法语义一致。
--   ★ 中括号不可省：string ->floatvector 要求用 [] 或 {} 包含数组。DEFAULT 表达式
--   在建表时不求值，所以漏掉中括号时建表照样"成功"，直到 INSERT 未显式写该列
--   才报 invalid input syntax for type floatvector: "0,0,..."
--   （应用层表现为 insert failed for table ...）。已建库需对相应列
--   ALTER COLUMN ... SET DEFAULT 修正，改本脚本对已存在的表无效。
-- ============================================================================

-- ============================================================================
-- 第一部分：【点表】核心业务实体 (Node Tables)
-- 注意：含 GIN 索引（tsvector/jsonb/数组）的表须 WITH (storage_type=astore)
--       （GaussVector 默认 Ustore 不支持 GIN，见设计文档 D9 / PoC P0-9 M4）；
--       纯向量/BM25/B-tree 表可用默认 Ustore。
-- ============================================================================

-- 1. 业务术语与逻辑实体表 (Semantic Terms)
-- 统一企业黑话与高度抽象的业务实体
-- astore：synonyms 数组列需建 GIN 索引（astore 支持 GIN，D9）
CREATE TABLE IF NOT EXISTS t_semantic_term (
    term_id UUID CONSTRAINT pk_term PRIMARY KEY DEFAULT uuid()::uuid,              -- DB 用 uuid() 生成（V7 UUID）
    name VARCHAR(255) NOT NULL CONSTRAINT uk_term_name UNIQUE,
    domain VARCHAR(100), -- 所属业务域（如 Finance 财务, Growth 增长）。帮助 Agent 在多义词冲突时限定上下文范围。
    synonyms TEXT[],  -- 同义词库。（如 ["GMV", "流水", "交易总额"]），扩展 Agent 的识别能力
    related_entity_type_id UUID, -- 关联的实体类型（多个术语可指向同一实体类型，FK 在 entity_type 创建后添加）
    -- floatvector 列级 NOT NULL（D3：GaussVector 不允许向量列 NULL/NaN/Inf，DB 层拦截）
    term_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),        -- 术语语义向量（bge-base-zh-v1.5，768 维）
    term_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),    -- 术语语义向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
) WITH (storage_type=astore);

-- 向量索引：HNSW → GsDiskANN（余弦距离，距离最小优先，ASC 走索引，P0-2/P0-3 已验）
-- enable_pq=false 适合作冷启动/小数据量；pq_nseg/pq_nclus 仅 enable_pq=true 时生效，
--   故冷启动阶段不传这两个参数（避免 "invalid due to enable_pq=true not meet" WARNING）。
--   生产 768/1024 维 + 数据充足后改 enable_pq=true 并加 pq_nseg=<维度>（见文末说明）
CREATE INDEX IF NOT EXISTS idx_term_term_vec
    ON t_semantic_term USING GsDiskANN (term_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_term_term_vec_m3
    ON t_semantic_term USING GsDiskANN (term_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_term_synonyms_gin
    ON t_semantic_term USING gin (synonyms)
    WHERE synonyms IS NOT NULL;
-- pg_trgm 索引已移除（GaussVector 不支持 gin_trgm_ops，模糊匹配降级为 ILIKE+应用层精排，见设计文档 §6）
-- 全文召回：原生 BM25（### 算子，内置 simple_cn_segmentation 中文分词）
-- GaussVector BM25 仅支持单列（VERIFY-11）且仅支持 TEXT 列（不支持 VARCHAR，实测
--   "Index type bm25 does not support data type character varying"）；semantic_term.name 是
--   VARCHAR(255)，故新增 search_text_bm25(TEXT 生成列 = name) 承载 BM25 召回。
--   synonyms 数组不并入 BM25（array_to_string 在生成列中非 immutable，实测不可用；
--   synonyms 精确命中走上面 GIN 索引）。
ALTER TABLE t_semantic_term ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(name, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_term_search_text_bm25 ON t_semantic_term
    USING BM25 (search_text_bm25);
CREATE INDEX IF NOT EXISTS idx_term_domain
    ON t_semantic_term (domain)
    WHERE domain IS NOT NULL;

-- 2. 数据表 (Physical Entities: Tables & Views)
-- 描述业务数据所在底层数据仓库的物理存储位置
CREATE TABLE IF NOT EXISTS t_semantic_data_table (
    entity_id UUID CONSTRAINT pk_data_table PRIMARY KEY DEFAULT uuid()::uuid,            -- DB 用 uuid() 生成（V7 UUID）
    entity_type VARCHAR(50) CHECK (entity_type IN ('PhysicalTable', 'VirtualView')), -- 物理类型（PhysicalTable 物理表, VirtualView 逻辑视图）
    schema_name VARCHAR(100) DEFAULT 'null',              -- 物理模式名（如 public, dwd）；哨兵见 uk_data_table_db_en_schema_table 注释
    table_name TEXT NOT NULL,      -- 真实的物理表名
    table_name_en TEXT,            -- 英文/逻辑表名（与 type.json、ingestion、data_column.table_name_en 对齐）
    db_name_en VARCHAR(100) DEFAULT 'null',               -- 业务/逻辑库名英文（与 ingestion、data_column.db_name_en、AdvancedSearch 过滤一致）；哨兵见注释
    table_id TEXT,                 -- 逻辑表标识（与 type.json data_table.table_id、列侧 table_id 对齐）
    source_type VARCHAR(100),
    table_name_ch TEXT,
    table_description TEXT,
    ddl TEXT,
    -- 表描述语义检索：table_description 的 embedding（与 type.json vectorIndex:"true" 对齐）
    table_description_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),        -- 表描述向量（bge-base-zh-v1.5，768 维）
    table_description_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),    -- 表描述向量（bge-m3，1024 维，多模型 RRF 召回）
    layer VARCHAR(50) CHECK (layer IN ('ODS', 'DWD', 'DWS', 'ADS')), -- 数仓分层（如 ODS, DWD, DWS），指导 Agent 优先选择加工好的高质量数据。
    column_descriptions TEXT,             -- 该实体表所有列名及其描述，格式：列名(类型): 描述；列名(类型): 描述；…
    qualified_name TEXT,          -- 全限定表名（如 postgres.public.orders_smoke）；供 AdvancedSearch table-relations-path 等解析
    data_retention_period_days INT,       -- 源系统中的留存期；NULL 表示未配置
    table_properties JSONB,               -- 表级语义组织元数据（dataset.custom_extensions.table_properties）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    -- 哨兵方案：约束列 schema_name/db_name_en 均可空但 DEFAULT 'null'（字符串，非 SQL NULL）。
    -- GaussVector 视空串 '' 为 NULL（DEFAULT '' 不可用，实测存成 NULL::character varying），
    -- 但非空串 'null' 作 DEFAULT 正常填值。客户端不传/传 null（normalizeAttributeKeys 过滤）→ 缺列 →
    -- 走 DEFAULT 填字符串 'null'，多条缺失行的约束键归一为 ('null','null',table_name) → 撞 UNIQUE 防重复。
    CONSTRAINT uk_data_table_db_en_schema_table UNIQUE(db_name_en, schema_name, table_name)
) WITH (storage_type=astore);

CREATE INDEX IF NOT EXISTS idx_data_table_desc_vec
    ON t_semantic_data_table USING GsDiskANN (table_description_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_data_table_desc_vec_m3
    ON t_semantic_data_table USING GsDiskANN (table_description_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE UNIQUE INDEX IF NOT EXISTS idx_data_table_table_id
    ON t_semantic_data_table (table_id) WHERE table_id IS NOT NULL;

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(table_name, '') || ' ' || COALESCE(table_name_en, '') || ' ' ||
    COALESCE(db_name_en, '') || ' ' || COALESCE(table_name_ch, '') || ' ' ||
    COALESCE(table_description, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(layer, '') || ' ' ||
    COALESCE(column_descriptions)
) STORED;
-- pg_trgm 索引已移除；search_text 仅作 BM25 源（下方 search_text_bm25 已覆盖核心召回）

ALTER TABLE t_semantic_data_table ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(table_name, '') || ' ' || COALESCE(table_description)
) STORED;
-- 全文召回：原生 BM25（### 算子，simple_cn_segmentation 中文分词），单列索引
CREATE INDEX IF NOT EXISTS idx_data_table_search_text_bm25 ON t_semantic_data_table
    USING BM25 (search_text_bm25);
-- pg_trgm 索引（ddl gin_trgm_ops）已移除；ddl 模糊匹配走 ILIKE

-- 3. 业务列表 (Data Columns)
-- 描述业务实体（semantic_term）的具体属性，承接物理列与业务概念的映射。通常通过table_has_column边表关联到data_table
CREATE TABLE IF NOT EXISTS t_semantic_data_column (
    dimension_id UUID CONSTRAINT pk_data_column PRIMARY KEY DEFAULT uuid()::uuid,            -- DB 用 uuid() 生成（V7 UUID）
    name TEXT NOT NULL,
    qualified_name TEXT,           -- Atlas/Referenceable 列唯一限定名（与 ingestion qualifiedName 一致）
    is_primary_key BOOLEAN DEFAULT FALSE,  -- 是否主键。让 Agent 知道该列是否可以作为 GROUP BY 或 DISTINCT 的依据
    -- 列语义检索：与 MetaVisor-main-2 DataColumn 的 column_description_short_vector 对齐（嵌入源优先 column_description_short）
    column_description_short_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),       -- 列描述向量（bge-base-zh-v1.5，768 维）
    column_description_short_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),   -- 列描述向量（bge-m3，1024 维，多模型 RRF 召回）
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
    db_name_en VARCHAR(100) DEFAULT 'null',               -- 业务库别名（英文），与 AdvancedSearch table-columns-info / column-value-info 两段式、三段式命名对齐；哨兵见 uk_data_column_db_table_column 注释
    table_name_en TEXT DEFAULT 'null',          -- 物理表名（不含 schema），如 orders_smoke；哨兵见注释
    table_id TEXT,               -- 父 data_table 逻辑标识（对齐 Atlas type.json data_column.table_id）
    column_name_en TEXT DEFAULT 'null',         -- 列名英文，如 order_id；哨兵见注释
    value_type TEXT NOT NULL,   -- 物理/逻辑类型（如 VARCHAR、bigint），供 Agent 引号与函数选择与过滤展示
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_data_column_db_table_column UNIQUE (db_name_en, table_name_en, column_name_en)
) WITH (storage_type=astore);

CREATE INDEX IF NOT EXISTS idx_data_column_col_short_vec
    ON t_semantic_data_column USING GsDiskANN (column_description_short_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_data_column_col_short_vec_m3
    ON t_semantic_data_column USING GsDiskANN (column_description_short_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(column_name_desc, '') || ' ' || COALESCE(column_description, '') || ' ' ||
    COALESCE(column_description_short, '') || ' ' || COALESCE(column_name_en)
) STORED;
-- pg_trgm 索引已移除

ALTER TABLE t_semantic_data_column ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(column_description_short)
) STORED;
-- 全文召回：原生 BM25，单列索引（simple_cn_segmentation 中文分词）
CREATE INDEX IF NOT EXISTS idx_data_column_search_text_bm25 ON t_semantic_data_column
    USING BM25 (search_text_bm25);

-- 3b. 列值表 (Data Column Values)
-- 对齐 Atlas type.json data_column_value：独立实体存放列值信息，通过 column_has_value 关系关联到 data_column
-- 注：所有 4 个向量列均 NOT NULL（D3）。若业务存在"只有 val 无 desc"场景，
--     应用层须保证 desc/val 均提供非空向量（设计文档 §5.4 待确认）。
CREATE TABLE IF NOT EXISTS t_semantic_data_column_value (
    value_id UUID CONSTRAINT pk_data_column_value PRIMARY KEY DEFAULT uuid()::uuid,            -- DB 用 uuid() 生成（V7 UUID）
    name VARCHAR(255),                   -- 展示名（与 Atlas/Referenceable、ingestion name 对齐）
    qualified_name VARCHAR(500),          -- 全限定名（与 ingestion qualifiedName、column_has_value 端点解析一致）
    value VARCHAR(255) NOT NULL,          -- 列取值（如 VIP、高价值客户）
    description TEXT,                     -- 列取值描述（如 高价值客户）；语义检索与 description_vector 对齐 main-2 data_column_value_enum
    description_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),            -- 描述文本嵌入（bge-base-zh-v1.5，768 维）
    description_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),        -- 描述文本嵌入（bge-m3，1024 维，多模型 RRF 召回）
    column_name_en VARCHAR(200),               -- 所属列名（英文），与 data_column.column_name_en 对齐
    table_name_en TEXT,                         -- 所属物理表名（不含 schema），与 data_column.table_name_en 对齐
    db_name_en VARCHAR(100),                   -- 业务库别名（英文），与 data_column.db_name_en 对齐
    -- 兼容旧逻辑：按取值字面量的向量；列值语义检索主路径为 description_vector
    value_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),                  -- 取值字面量向量（bge-base-zh-v1.5，768 维）
    value_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),              -- 取值字面量向量（bge-m3，1024 维，多模型 RRF 召回）
    value_type VARCHAR(50),                    -- 取值类型（如 enum），与 data_column.value_type 对齐
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_data_column_value_value_vec
    ON t_semantic_data_column_value USING GsDiskANN (value_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_data_column_value_value_vec_m3
    ON t_semantic_data_column_value USING GsDiskANN (value_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_data_column_value_desc_vec
    ON t_semantic_data_column_value USING GsDiskANN (description_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_data_column_value_desc_vec_m3
    ON t_semantic_data_column_value USING GsDiskANN (description_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_data_column_value_column
    ON t_semantic_data_column_value (column_name_en, table_name_en, db_name_en);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE("value", '') || ' ' || COALESCE(description)
) STORED;
-- pg_trgm 索引已移除

ALTER TABLE t_semantic_data_column_value ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE("value", '') || ' ' || COALESCE(description)
) STORED;
-- 全文召回：原生 BM25，单列索引
CREATE INDEX IF NOT EXISTS idx_data_column_value_search_text_bm25 ON t_semantic_data_column_value
    USING BM25 (search_text_bm25);

-- 4. SQL 过程点表 (sql_process)
-- 对齐 MetaVisor type.json：sql_process（superTypes Process）；用于登记 Golden SQL / 典型查询及其用到的列
CREATE TABLE IF NOT EXISTS t_semantic_sql_process (
    process_id UUID CONSTRAINT pk_sql_process PRIMARY KEY DEFAULT uuid()::uuid,          -- DB 用 uuid() 生成（V7 UUID）
    name VARCHAR(500),                   -- 展示名（与 Atlas/Referenceable、ingestion name 对齐）
    qualified_name VARCHAR(500),         -- 全限定名（与 Atlas/Referenceable、ingestion qualifiedName 端点解析一致）
    sql_id VARCHAR(255) NOT NULL,            -- 业务侧 SQL 标识，与 expression 均在 Atlas 上标为唯一
    expression TEXT NOT NULL,              -- SQL 文本或规范化表达式
    source_tables TEXT[],                   -- SQL 过程源表
    target_table TEXT,                      -- SQL 过程目标表
    intent TEXT,                           -- 可检索的意图摘要
    query TEXT,                            -- 自然语言问法或检索文本；可选建向量索引
    query_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),  -- NL 问法向量（bge-base-zh-v1.5，768 维）
    query_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- NL 问法向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_sql_process_sql_id UNIQUE (sql_id)
) WITH (storage_type=astore);

-- pg_trgm 索引（intent/query gin_trgm_ops）已移除；模糊匹配走 BM25/ILIKE
CREATE INDEX IF NOT EXISTS idx_sql_process_query_vector_gsdiskann
    ON t_semantic_sql_process USING GsDiskANN (query_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_sql_process_query_vector_gsdiskann_m3
    ON t_semantic_sql_process USING GsDiskANN (query_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_sql_process ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(sql_id, '') || ' ' || COALESCE(intent, '') || ' ' ||
    COALESCE(query)
) STORED;
-- pg_trgm 索引已移除

ALTER TABLE t_semantic_sql_process ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(intent, '') || ' ' || COALESCE(query)
) STORED;
-- 全文召回：原生 BM25，单列索引
CREATE INDEX IF NOT EXISTS idx_sql_process_search_text_bm25 ON t_semantic_sql_process
    USING BM25 (search_text_bm25);

-- 5. 知识证据表 (Knowledge Evidence)
-- schema-free 抽取的业务知识语料（会议纪要/Wiki 规则/Golden SQL），承载向量 + 图检索索引键
CREATE TABLE IF NOT EXISTS t_semantic_knowledge_evidence (
    evidence_id UUID CONSTRAINT pk_knowledge_evidence PRIMARY KEY DEFAULT uuid()::uuid,         -- DB 用 uuid() 生成（V7 UUID）
    name VARCHAR(255) NOT NULL,            -- 证据标题（如：Q3财报营收对齐会议纪要）
    evidence_type VARCHAR(50) CHECK (
        evidence_type IS NULL
        OR evidence_type IN ('Golden_SQL', 'Meeting_Note', 'Wiki_Rule')
    ),                                     -- 证据类型：语义上的证据类别；无法明确时可置 NULL
    raw_text TEXT NOT NULL,                -- 原始文本语料
    confidence_score INT CHECK (confidence_score BETWEEN 0 AND 100), -- 置信度（0-100），用于召回排序
    embedding floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- 文本向量，使用 BAAI/bge-m3 (1024 维) 进行相似度检索
    -- schema-free 抽取结果：实体与关系
    entities JSONB NOT NULL DEFAULT '[]'::jsonb,
    relations JSONB NOT NULL DEFAULT '[]'::jsonb,
    -- 图检索索引键（从 entities/relations 归一化提取，便于 GIN overlap 检索）
    entity_keys TEXT[] NOT NULL DEFAULT '{}',
    relation_keys TEXT[] NOT NULL DEFAULT '{}',
    -- 全文召回由下方 search_text_bm25 上的原生 BM25 索引承担（simple_cn_segmentation 中文分词）
    status VARCHAR(20) DEFAULT 'Active',
    expression TEXT,
    intent TEXT,
    query TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_knowledge_evidence_name UNIQUE (name)
) WITH (storage_type=astore);

-- 针对证据表建立向量索引 + 常用过滤索引，支持毫秒级相似度召回与快速过滤
CREATE INDEX IF NOT EXISTS idx_evidence_vector_gsdiskann ON t_semantic_knowledge_evidence
    USING GsDiskANN (embedding Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_evidence_type_status ON t_semantic_knowledge_evidence (evidence_type, status);
CREATE INDEX IF NOT EXISTS idx_evidence_entity_keys ON t_semantic_knowledge_evidence USING gin (entity_keys);
CREATE INDEX IF NOT EXISTS idx_evidence_relation_keys ON t_semantic_knowledge_evidence USING gin (relation_keys);
CREATE INDEX IF NOT EXISTS idx_evidence_entities_jsonb ON t_semantic_knowledge_evidence USING gin (entities);
CREATE INDEX IF NOT EXISTS idx_evidence_relations_jsonb ON t_semantic_knowledge_evidence USING gin (relations);

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_knowledge_evidence ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(raw_text)
) STORED;
-- 全文召回：原生 BM25，单列索引（simple_cn_segmentation 中文分词）
CREATE INDEX IF NOT EXISTS idx_knowledge_evidence_search_text_bm25 ON t_semantic_knowledge_evidence
    USING BM25 (search_text_bm25);

-- knowledge_evidence 的规范化关系边（用于图查询）
-- astore：search_vector(tsvector) 需建 GIN 索引（Ustore 不支持 GIN，D9/M4，PoC P0-9 已验）
CREATE TABLE IF NOT EXISTS t_semantic_knowledge_evidence_edge (
    edge_id UUID CONSTRAINT pk_knowledge_evidence_edge PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    evidence_id UUID NOT NULL REFERENCES t_semantic_knowledge_evidence(evidence_id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,      -- chunk name，便于排查与回表聚合
    src TEXT NOT NULL,
    predicate TEXT NOT NULL,
    dst TEXT NOT NULL,
    edge_text TEXT NOT NULL DEFAULT '',   -- 人类可读的短句（检索与展示）
    edge_embedding floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- 与 chunk 相同：BAAI/bge-m3
    -- tsvector 生成列：regconfig 用 'simple'（GaussVector 无 'chinese'，M3；应用侧 tsvectorRecall 传 'simple'/'ngram'）
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
) WITH (storage_type=astore);
CREATE INDEX IF NOT EXISTS idx_ke_edge_evidence_id ON t_semantic_knowledge_evidence_edge (evidence_id);
CREATE INDEX IF NOT EXISTS idx_ke_edge_src ON t_semantic_knowledge_evidence_edge (src);
CREATE INDEX IF NOT EXISTS idx_ke_edge_dst ON t_semantic_knowledge_evidence_edge (dst);
CREATE INDEX IF NOT EXISTS idx_ke_edge_predicate ON t_semantic_knowledge_evidence_edge (predicate);
CREATE INDEX IF NOT EXISTS idx_ke_edge_spd ON t_semantic_knowledge_evidence_edge (src, predicate, dst);
-- pg_trgm 索引（src/dst/predicate/haystack gin_trgm_ops）已全部移除（GaussVector 不支持 gin_trgm_ops）
-- haystack 模糊匹配降级为 ILIKE + 应用层 DefaultTrigramFallback 精排（设计文档 §6）
CREATE INDEX IF NOT EXISTS idx_ke_edge_search_vector ON t_semantic_knowledge_evidence_edge USING gin (search_vector);
CREATE INDEX IF NOT EXISTS idx_ke_edge_embedding_gsdiskann ON t_semantic_knowledge_evidence_edge
    USING GsDiskANN (edge_embedding Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);

-- 6. 治理策略表 (Governance Policies)
-- 定义数据脱敏、过滤、屏蔽等治理策略，用于保护敏感数据
CREATE TABLE IF NOT EXISTS t_semantic_governance_policy (
    policy_id UUID CONSTRAINT pk_governance_policy PRIMARY KEY DEFAULT uuid()::uuid,           -- DB 用 uuid() 生成（V7 UUID）
    name VARCHAR(255) NOT NULL,
    policy_level VARCHAR(50) CHECK (policy_level IN ('Row', 'Column', 'Table')), -- 策略生效层级（如 Row 行级, Column 列级, Table 表级）
    enforcement_type VARCHAR(50) CHECK (enforcement_type IN ('Masking', 'Filtering', 'Block', 'Required', 'Pattern', 'Enum', 'Range', 'CustomValidate', 'Transform')), -- 执行类型（如 Masking 脱敏, Filtering 过滤, Block 屏蔽）
    rule_definition TEXT NOT NULL,         -- 具体的执行规则，大模型会根据这个定义（例如：将所有手机号替换为星号）去改写最终生成的sql
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
-- pg_trgm 索引已移除（search_text 仅作展示/ILIKE 源，无 BM25 召回需求）

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_governance_policy ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(policy_level, '') || ' ' ||
    COALESCE(enforcement_type, '') || ' ' || COALESCE(rule_definition)
) STORED;

-- 7. 动作与工具表 (Agent Actions)
-- 定义具体的系统动作与工具，如查询、分析、报告生成等
CREATE TABLE IF NOT EXISTS t_semantic_agent_action (
    action_id UUID CONSTRAINT pk_agent_action PRIMARY KEY DEFAULT uuid()::uuid,           -- DB 用 uuid() 生成（V7 UUID）
    name VARCHAR(255) NOT NULL CONSTRAINT uk_agent_action_name UNIQUE,
    execution_mode VARCHAR(50) CHECK (execution_mode IN ('Sync', 'Async')), -- 执行模式（Sync 同步, Async 异步）告诉Agent调用后是应该原地等待结果，还是异步返回id
    endpoint VARCHAR(255),                  -- Action Service POST URL；执行 Sync 动作时应配置可达地址
    parameters_schema JSONB NOT NULL,       -- 参数定义规范，作为Function Call的元数据
    status VARCHAR(20) DEFAULT 'Active',
    logic TEXT,                   -- action的执行逻辑，如果不存在预制action，则需要根据这个logic生成action
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
-- pg_trgm 索引已移除

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_agent_action ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(execution_mode)
) STORED;

-- 8. UDF 函数表 (Udf Functions)
-- 定义用户自定义函数，供 SQL 表达式中使用
CREATE TABLE IF NOT EXISTS t_semantic_udf_function (
    function_id UUID CONSTRAINT pk_udf_function PRIMARY KEY DEFAULT uuid()::uuid,         -- DB 用 uuid() 生成（V7 UUID）
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
-- pg_trgm 索引已移除

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_udf_function ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(category, '') || ' ' || COALESCE(prototype, '') || ' ' ||
    COALESCE(function_description)
) STORED;

-- 9. 指标分组表 (Metric Groups)
-- 指标的分组/目录结构，支持层级树形组织
CREATE TABLE IF NOT EXISTS t_semantic_metric_group (
    group_id UUID CONSTRAINT pk_metric_group PRIMARY KEY DEFAULT uuid()::uuid,            -- DB 用 uuid() 生成（V7 UUID）
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
-- pg_trgm 索引已移除

CREATE INDEX IF NOT EXISTS idx_metric_group_parent
    ON t_semantic_metric_group (parent_group_code);
CREATE INDEX IF NOT EXISTS idx_metric_group_domain
    ON t_semantic_metric_group (domain) WHERE domain IS NOT NULL;

-- Atlas entityText equivalent: concatenate all searchable text attributes for fulltext search
ALTER TABLE t_semantic_metric_group ADD COLUMN IF NOT EXISTS search_text TEXT GENERATED ALWAYS AS (
    COALESCE(name, '') || ' ' || COALESCE(qualified_name, '') || ' ' ||
    COALESCE(group_code, '') || ' ' || COALESCE(group_path, '') || ' ' ||
    COALESCE(domain, '') || ' ' || COALESCE(description)
) STORED;

-- 10. 指标实例表 (Metric Instances)
-- 具体的指标实例，承载业务口径、计算逻辑与物化信息；合并原 semantic_metric 的定义字段
CREATE TABLE IF NOT EXISTS t_semantic_metric_instance (
    instance_id UUID CONSTRAINT pk_metric_instance PRIMARY KEY DEFAULT uuid()::uuid,         -- DB 用 uuid() 生成（V7 UUID）
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
    metric_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),   -- 指标语义向量（bge-base-zh-v1.5，768 维）
    metric_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- 指标语义向量（bge-m3，1024 维，多模型 RRF 召回）
    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
) WITH (storage_type=astore);

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
    COALESCE(unit, '') || ' ' || COALESCE(data_type)
) STORED;
-- pg_trgm 索引已移除

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
    COALESCE(unit, '') || ' ' || COALESCE(data_type)
) STORED;
-- 全文召回：原生 BM25，单列索引
CREATE INDEX IF NOT EXISTS idx_metric_instance_search_text_bm25 ON t_semantic_metric_instance
    USING BM25 (search_text_bm25);
CREATE INDEX IF NOT EXISTS idx_metric_instance_metric_vec
    ON t_semantic_metric_instance USING GsDiskANN (metric_vector Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_metric_instance_metric_vec_m3
    ON t_semantic_metric_instance USING GsDiskANN (metric_vector_m3 Cosine)
    WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1);
CREATE INDEX IF NOT EXISTS idx_metric_instance_synonyms_gin
    ON t_semantic_metric_instance USING gin (synonyms)
    WHERE synonyms IS NOT NULL;

-- 11. Action 执行日志表 (Action Execution Logs)
-- 记录 action 的每次触发与执行状态，支持轻量审计与失败排障
CREATE TABLE IF NOT EXISTS t_semantic_action_execution_log (
    execution_id UUID CONSTRAINT pk_action_execution_log PRIMARY KEY DEFAULT uuid()::uuid,        -- DB 用 uuid() 生成（V7 UUID）
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

-- 12. 更新事件 Outbox 表 (Update Event Outbox)
-- 使用 Outbox 模式承接语义层/数据层更新事件，异步触发 on_update action。
CREATE TABLE IF NOT EXISTS t_semantic_update_event_outbox (
    event_id UUID CONSTRAINT pk_update_event_outbox PRIMARY KEY DEFAULT uuid()::uuid,            -- DB 用 uuid() 生成（V7 UUID）
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
) WITH (storage_type=astore);
CREATE INDEX IF NOT EXISTS idx_update_event_outbox_pending ON t_semantic_update_event_outbox (status, available_at, created_at);
CREATE INDEX IF NOT EXISTS idx_update_event_outbox_created_at ON t_semantic_update_event_outbox (created_at DESC);


-- ============================================================================
-- 第二部分：【边表】业务关系路径 (Edge Tables)
-- ============================================================================

-- 1. 表关联路径 (TABLE_JOIN_RELATIONSHIP)
-- 描述数据表之间的关联关系，支持多对多、一对多、一对一等关联类型，即 Entity–TABLE_JOIN_RELATIONSHIP–Entity
CREATE TABLE IF NOT EXISTS t_semantic_edge_table_join_relationship (
    edge_id UUID CONSTRAINT pk_edge_table_join_relationship PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    source_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,
    target_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,

    join_type VARCHAR(50) CHECK (join_type IN ('LEFT JOIN', 'INNER JOIN', 'FULL OUTER JOIN')), -- 推荐的连接类型
    join_condition TEXT NOT NULL,          -- 连接条件模板（如 {source}.buyer_id = {target}.user_id）。Agent 生成 SQL 时无需猜测关联字段，直接将别名套入模板即可
    cardinality VARCHAR(20) CHECK (cardinality IN ('1:1', '1:N', 'N:1', 'N:M')), -- 基数/数据行数关系。如果标识为 1:N 或 N:M，系统级 Prompt 需要警告 Agent："在聚合计算前，必须先在子查询中对 target 表进行去重（GROUP BY），否则会导致 source 表的金额翻倍"。
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
    edge_id UUID CONSTRAINT pk_edge_sql_use_column PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
    edge_id UUID CONSTRAINT pk_edge_column_join_relationship PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
    edge_id UUID CONSTRAINT pk_edge_column_foreign_key_relationship PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
) WITH (storage_type=astore);
-- UUID[] 无默认 gin opclass，用 IMMUTABLE 函数 uuid_arr_to_text_arr 包装建表达式 GIN 索引
-- 查询对应改写：'<uuid>' = ANY(uuid_arr_to_text_arr(source_column_ids))
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_source_cols
    ON t_semantic_edge_column_foreign_key_relationship USING gin (uuid_arr_to_text_arr(source_column_ids));
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_target_cols
    ON t_semantic_edge_column_foreign_key_relationship USING gin (uuid_arr_to_text_arr(target_column_ids));
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_source_entity
    ON t_semantic_edge_column_foreign_key_relationship (source_entity_id);
CREATE INDEX IF NOT EXISTS idx_edge_column_fk_target_entity
    ON t_semantic_edge_column_foreign_key_relationship (target_entity_id);

-- 3. 列归属映射 (TABLE_HAS_COLUMN)
-- 描述业务列表如何归属到数据表，即逻辑属性对应到哪些物理表，即Column-TABLE_HAS_COLUMN-Entity
CREATE TABLE IF NOT EXISTS t_semantic_edge_table_has_column (
    edge_id UUID CONSTRAINT pk_edge_table_has_column PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
    edge_id UUID CONSTRAINT pk_edge_column_has_value PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
    edge_id UUID CONSTRAINT pk_edge_has_attribute PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
    edge_id UUID CONSTRAINT pk_edge_has_term PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
) WITH (storage_type=astore);
CREATE INDEX IF NOT EXISTS idx_edge_has_term_source_term ON t_semantic_edge_has_term (source_term_id);
CREATE INDEX IF NOT EXISTS idx_edge_has_term_target_term ON t_semantic_edge_has_term (target_term_id);
-- UUID[] 无默认 gin opclass，用 IMMUTABLE 函数 uuid_arr_to_text_arr 包装建表达式 GIN 索引
-- 查询对应改写：'<uuid>' = ANY(uuid_arr_to_text_arr(source_dimension_ids))
CREATE INDEX IF NOT EXISTS idx_edge_has_term_source_dims ON t_semantic_edge_has_term USING gin (uuid_arr_to_text_arr(source_dimension_ids));
CREATE INDEX IF NOT EXISTS idx_edge_has_term_target_dims ON t_semantic_edge_has_term USING gin (uuid_arr_to_text_arr(target_dimension_ids));

-- 5. 知识证据挂载 (DESCRIBES)
-- 描述知识证据如何挂载到业务实体、物理表实体、指标、列等。即Evidence-DESCRIBES-Entity/Metric/Column/Term
CREATE TABLE IF NOT EXISTS t_semantic_edge_describes (
    edge_id UUID CONSTRAINT pk_edge_describes PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    source_evidence_id UUID NOT NULL REFERENCES t_semantic_knowledge_evidence(evidence_id) ON DELETE CASCADE,

    target_type VARCHAR(50) CHECK (target_type IN ('Entity', 'Metric', 'Dimension', 'Term')),
    target_id UUID NOT NULL,

    relevance_score INT CHECK (relevance_score BETWEEN 0 AND 100), -- 相关性得分。用于衡量证据与目标的相关性，辅助Agent在多维分析时快速锁定目标。
    applied_scenario VARCHAR(100), -- 应用场景（如 Exception_Handling 异常处理, Definition 口径定义）。当用户询问"异常数据"时，优先召回此类文档。

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_describes_source_evidence_target_type_target UNIQUE(source_evidence_id, target_type, target_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_desc_target ON t_semantic_edge_describes(target_type, target_id);

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
    edge_id UUID CONSTRAINT pk_edge_restricts PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    source_policy_id UUID NOT NULL REFERENCES t_semantic_governance_policy(policy_id) ON DELETE CASCADE,

    target_type VARCHAR(50) CHECK (target_type IN ('Entity', 'Dimension', 'Action')), -- 目标粗分类（Object 模式使用）
    target_id UUID,                                                                     -- 目标记录 UUID（Object 模式使用, OSI 导入时由 target_ref 解析）
    target_scope VARCHAR(50) CHECK (target_scope IN ('Table', 'Field', 'Object')),       -- 生效层级: Table=整表, Field=某列, Object=某条记录
    target_table VARCHAR(100) CHECK (
        target_table IS NULL
        OR target_table IN (
            'semantic_term', 'data_table', 'data_column', 'data_column_value', 'sql_process',
            'knowledge_evidence', 'governance_policy', 'agent_action', 'udf_function',
            'metric_group', 'metric_instance', 'knowledge_evidence_edge', 'action_execution_log',
            'update_event_outbox', 'edge_table_join_relationship', 'edge_sql_use_column',
            'edge_column_join_relationship', 'edge_column_foreign_key_relationship',
            'edge_table_has_column', 'edge_column_has_value', 'edge_has_attribute',
            'edge_has_term', 'edge_describes', 'edge_restricts', 'edge_triggers',
            'edge_metric_instance_belongs_group', 'edge_metric_instance_realized_in_table',
            'edge_metric_instance_uses_column', 'edge_metric_instance_derived_from_instance'
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
CREATE INDEX IF NOT EXISTS idx_edge_restricts_target ON t_semantic_edge_restricts(target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_edge_restricts_target_scope
    ON t_semantic_edge_restricts(target_scope, target_table, target_field);

-- 7. 系统动作触发 (TRIGGERS)
-- 定义特定实体，指标相关的action，即Entity/Metric-TRIGGERS-Action
CREATE TABLE IF NOT EXISTS t_semantic_edge_triggers (
    edge_id UUID CONSTRAINT pk_edge_triggers PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
CREATE INDEX IF NOT EXISTS idx_edge_triggers_source ON t_semantic_edge_triggers(source_type, source_id);

-- 8. 指标实例归属分组 (METRIC_INSTANCE_BELONGS_GROUP)
-- 描述指标实例归属到哪个指标分组，即 MetricGroup-BELONGS_GROUP-MetricInstance
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_belongs_group (
    edge_id UUID CONSTRAINT pk_edge_metric_instance_belongs_group PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
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
    edge_id UUID CONSTRAINT pk_edge_metric_instance_realized_in_table PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    source_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,
    target_entity_id UUID NOT NULL REFERENCES t_semantic_data_table(entity_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_edge_mi_realized_instance_table UNIQUE(source_instance_id, target_entity_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_realized_instance ON t_semantic_edge_metric_instance_realized_in_table (source_instance_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_realized_table ON t_semantic_edge_metric_instance_realized_in_table (target_entity_id);

-- 10. 指标实例使用数据列 (METRIC_INSTANCE_USES_COLUMN)
-- 描述指标实例使用了哪些数据列，即 MetricInstance-USES_COLUMN-DataColumn
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_uses_column (
    edge_id UUID CONSTRAINT pk_edge_metric_instance_uses_column PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    source_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,
    target_dimension_id UUID NOT NULL REFERENCES t_semantic_data_column(dimension_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_edge_mi_uses_col_instance_dimension UNIQUE(source_instance_id, target_dimension_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_uses_col_instance ON t_semantic_edge_metric_instance_uses_column (source_instance_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_uses_col_dimension ON t_semantic_edge_metric_instance_uses_column (target_dimension_id);

-- 11. 指标实例派生关系 (METRIC_INSTANCE_DERIVED_FROM_INSTANCE)
-- 描述指标实例间的派生/依赖关系，即 MetricInstance-DERIVED_FROM_INSTANCE-MetricInstance
CREATE TABLE IF NOT EXISTS t_semantic_edge_metric_instance_derived_from_instance (
    edge_id UUID CONSTRAINT pk_edge_metric_instance_derived_from_instance PRIMARY KEY DEFAULT uuid()::uuid,             -- DB 用 uuid() 生成（V7 UUID）
    source_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,
    target_instance_id UUID NOT NULL REFERENCES t_semantic_metric_instance(instance_id) ON DELETE CASCADE,

    status VARCHAR(20) DEFAULT 'Active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_edge_mi_derived_source_target UNIQUE(source_instance_id, target_instance_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_mi_derived_source ON t_semantic_edge_metric_instance_derived_from_instance (source_instance_id);
CREATE INDEX IF NOT EXISTS idx_edge_mi_derived_target ON t_semantic_edge_metric_instance_derived_from_instance (target_instance_id);

-- ============================================================================
-- 列注释：将 DDL 内联 -- 注释写入 pg_description，
-- 供 SemanticLayerSchemaService 直接从元数据读取，无需依赖外部 SQL 文件。
-- （COMMENT ON 在 GaussVector 103.0.0 实测可用）
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
-- 主键命名约定：所有表的主键统一为 id UUID DEFAULT uuid()::uuid
-- （GaussVector 无 uuid_generate_v4()，用内置 uuid()（返回 varchar 须 ::uuid cast）作列 DEFAULT；uuid() 返回 V7 时间戳排序 UUID（非 PG 的 V4 随机 UUID），详见 docs/design/gaussvector-backend-design.md）。
-- 与语义层已有表风格一致。
-- ============================================================================

-- ============================================================================
-- 1. ontology_definition（本体定义表）
-- 面向特定场景的完整本体。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_definition (
    id UUID CONSTRAINT pk_ontology_definition PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
    api_name VARCHAR(255) NOT NULL CONSTRAINT uk_ontology_definition_api_name UNIQUE,
    display_name VARCHAR(255),
    description TEXT,
    search_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),  -- 本体检索向量（bge-base-zh-v1.5，768 维，06 报告 FR-1.1；失效=全零向量）
    search_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- 本体检索向量（bge-m3，1024 维，双模型 RRF 召回）
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ontology_def_api_name ON t_semantic_ontology_definition (api_name);
-- 本体检索基建（06 报告 FR-1.1，GaussVector 语法）：GsDiskANN 向量索引 + 原生 BM25（simple_cn_segmentation 分词）
CREATE INDEX IF NOT EXISTS idx_ontology_def_search_vec
    ON t_semantic_ontology_definition USING GsDiskANN (search_vector Cosine);
CREATE INDEX IF NOT EXISTS idx_ontology_def_search_vec_m3
    ON t_semantic_ontology_definition USING GsDiskANN (search_vector_m3 Cosine);
ALTER TABLE t_semantic_ontology_definition ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(api_name, '') || ' ' || COALESCE(display_name, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_ontology_def_bm25 ON t_semantic_ontology_definition
    USING BM25 (search_text_bm25);


-- ============================================================================
-- 2. entity_type（实体类型定义表）
-- EntityType 的独立定义表，api_name 为本体层实体唯一标识。
-- 通过 semantic_term.related_entity_type_id 反向关联，维持 N:1 关系
--（多个 semantic_term 可关联到同一个 entity_type）。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_entity_type (
    id UUID CONSTRAINT pk_entity_type PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
    api_name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    description TEXT,
    search_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),  -- 本体检索向量（bge-base-zh-v1.5，768 维，06 报告 FR-1.1；失效=全零向量）
    search_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- 本体检索向量（bge-m3，1024 维，双模型 RRF 召回）
    primary_property_names TEXT[] DEFAULT '{}'::TEXT[],
    title_property_names TEXT[] DEFAULT '{}'::TEXT[],
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
) WITH (storage_type=astore);

CREATE INDEX IF NOT EXISTS idx_et_api_name ON t_semantic_entity_type (api_name);
-- 本体检索基建（06 报告 FR-1.1，GaussVector 语法）：GsDiskANN 向量索引 + 原生 BM25（simple_cn_segmentation 分词）
CREATE INDEX IF NOT EXISTS idx_et_search_vec
    ON t_semantic_entity_type USING GsDiskANN (search_vector Cosine);
CREATE INDEX IF NOT EXISTS idx_et_search_vec_m3
    ON t_semantic_entity_type USING GsDiskANN (search_vector_m3 Cosine);
ALTER TABLE t_semantic_entity_type ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(api_name, '') || ' ' || COALESCE(display_name, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_et_bm25 ON t_semantic_entity_type
    USING BM25 (search_text_bm25);


-- ============================================================================
-- 3. relation_type（关系类型定义表）
-- RelationType 的独立定义，引用 entity_type（source/target），
-- 只存储语义层缺少的字段。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_relation_type (
    id UUID CONSTRAINT pk_relation_type PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
    api_name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    description TEXT,
    search_vector floatvector(768) DEFAULT ('[' || repeat('0,', 767) || '0]')::floatvector(768),  -- 本体检索向量（bge-base-zh-v1.5，768 维，06 报告 FR-1.1；失效=全零向量）
    search_vector_m3 floatvector(1024) DEFAULT ('[' || repeat('0,', 1023) || '0]')::floatvector(1024),  -- 本体检索向量（bge-m3，1024 维，双模型 RRF 召回）
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
) WITH (storage_type=astore);

CREATE INDEX IF NOT EXISTS idx_rt_api_name ON t_semantic_relation_type (api_name);
CREATE INDEX IF NOT EXISTS idx_rt_source_entity ON t_semantic_relation_type (source_entity_type_id);
CREATE INDEX IF NOT EXISTS idx_rt_target_entity ON t_semantic_relation_type (target_entity_type_id);
-- 本体检索基建（06 报告 FR-1.1，GaussVector 语法）：GsDiskANN 向量索引 + 原生 BM25（simple_cn_segmentation 分词）
CREATE INDEX IF NOT EXISTS idx_rt_search_vec
    ON t_semantic_relation_type USING GsDiskANN (search_vector Cosine);
CREATE INDEX IF NOT EXISTS idx_rt_search_vec_m3
    ON t_semantic_relation_type USING GsDiskANN (search_vector_m3 Cosine);
ALTER TABLE t_semantic_relation_type ADD COLUMN IF NOT EXISTS search_text_bm25 TEXT GENERATED ALWAYS AS (
    COALESCE(api_name, '') || ' ' || COALESCE(display_name, '') || ' ' || COALESCE(description, '')
) STORED;
CREATE INDEX IF NOT EXISTS idx_rt_bm25 ON t_semantic_relation_type
    USING BM25 (search_text_bm25);


-- ============================================================================
-- 4. ontology_property_binding（属性绑定表）
-- 场景级属性覆盖：同一语义层属性在不同本体中可有不同的 API 名、展示名。
-- owner_type = 'EntityType' 或 'RelationType'，owner_id 引用 entity_type/relation_type 的 id。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_property_binding (
    id UUID CONSTRAINT pk_ontology_property_binding PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
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
    CONSTRAINT uk_ontology_property_binding_owner UNIQUE(owner_type, owner_id, property_api_name)
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
    id UUID CONSTRAINT pk_database_info PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
    data_source_name VARCHAR(255) NOT NULL CONSTRAINT uk_database_info_data_source_name UNIQUE,
    data_source_type VARCHAR(50) NOT NULL,
    connection_string TEXT,  -- Changed from NOT NULL to nullable to preserve distinction between null and empty string
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_database_info_name ON t_semantic_database_info (data_source_name);

-- ============================================================================
-- 6. ontology_data_source_binding（数据源绑定表）
-- 实体/关系类型 → 物理数据表的绑定，通过 database_id 引用连接配置。
-- 将连接信息与绑定信息分离，便于对不同级别信息做不同安全管控。
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_semantic_ontology_data_source_binding (
    id UUID CONSTRAINT pk_ontology_data_source_binding PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
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
) WITH (storage_type=astore);

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
    id UUID CONSTRAINT pk_ontology_domain PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
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
    id UUID CONSTRAINT pk_ontology_domain_group PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
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
    id UUID CONSTRAINT pk_ontology_domain_own_entity_type PRIMARY KEY DEFAULT uuid()::uuid,                  -- DB 用 uuid() 生成（V7 UUID）
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
-- 用 DO $$ IF NOT EXISTS 包裹：GV 不支持 ADD CONSTRAINT IF NOT EXISTS（语法错误），
-- 包裹后重复执行幂等（约束已存在则跳过）。
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_semantic_term_entity_type') THEN
        ALTER TABLE t_semantic_term
            ADD CONSTRAINT fk_semantic_term_entity_type
            FOREIGN KEY (related_entity_type_id) REFERENCES t_semantic_entity_type(id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_term_entity_type ON t_semantic_term (related_entity_type_id);

-- ============================================================================
-- 扩展部分：t_semantic_ingestion_trace（ingestion job 状态管理表）
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

-- ============================================================================
-- 文末说明：GsDiskANN 参数与生产调优
-- ============================================================================
-- 本脚本 GsDiskANN 索引统一用 enable_pq=false（冷启动/小数据量友好：
-- enable_pq=true 时若数据不足会 WARNING "There is not enough data to construct
-- PQ index, try to build LVQ index"，PoC VERIFY-10 已观测）。
-- 生产环境 768/1024 维 + 数据量充足后，建议重建索引切到 PQ 加速：
--   DROP INDEX <idx>; CREATE INDEX <idx> ON <tbl> USING GsDiskANN (<vec> Cosine)
--     WITH (graph_degree=96, pq_nseg=768, pq_nclus=16, num_parallels=10,
--           enable_pq=true, subgraph_count=1);
--   （1024 维向量把 pq_nseg 改为 1024；pq_nseg 必须整除向量维度，仅 enable_pq=true 时生效）
-- 查实际生效参数：SELECT * FROM gs_vector_index_options('<idx>');
-- 查索引健康度：  SELECT * FROM gs_diskann_inspect('<idx>');
-- ============================================================================

-- ============================================================================
-- 与 PostgreSQL 脚本（create_semantic_layer.sql）的差异说明
-- ============================================================================
-- | # | 类别            | PostgreSQL 版                                    | GaussVector 版（本文件）                                                                              | 依据 |
-- |---|----------------|--------------------------------------------------|--------------------------------------------------------------------------------------------------------|------|
-- | 1 | 扩展声明        | CREATE EXTENSION uuid-ossp / vector / pg_trgm / pg_search | 删除全部 CREATE EXTENSION（向量/BM25/UUID 均为 GaussVector 内置）                              | D1/§4.1 |
-- | 2 | 向量列类型      | vector(768/1024)，可空                            | floatvector(768/1024) NOT NULL（D3：GaussVector 列级不允许 NULL/NaN/Inf）                            | P0-2/§4.1 |
-- | 3 | 向量索引        | USING hnsw (col vector_cosine_ops) WITH (m=16, ef_construction=64) | USING GsDiskANN (col Cosine) WITH (graph_degree=96, num_parallels=10, enable_pq=false, subgraph_count=1)（冷启动不传 pq_nseg/pq_nclus，二者仅 enable_pq=true 时生效；生产切 PQ 时再加 pq_nseg=<维度>） | P0-3/§4.3 |
-- | 4 | 向量索引谓词    | HNSW 带 WHERE col IS NOT NULL（列可空）          | 去掉 WHERE 谓词（floatvector 列已 NOT NULL，谓词多余；实测带/不带均可用）                             | D3/VERIFY-9 |
-- | 5 | UUID DEFAULT   | DEFAULT uuid_generate_v4()                       | DEFAULT uuid()::uuid（GaussVector 无 uuid_generate_v4()；内置 uuid() 返回 varchar 须 ::uuid cast；**uuid() 返回 V7 时间戳排序 UUID（前 48 位毫秒时间戳），非 PG 的 V4 随机 UUID**，此点需 GV 人员确认是否满足业务，详见 docs/design/gaussvector-backend-design.md §9.2） | §4.1/§4.4 + 实测 |
-- | 6 | BM25 索引       | USING bm25 (key, col1, col2) WITH (key_field=..., text_fields='{"..":{"tokenizer":{"type":"chinese_lindera"}}}') 多列 | USING BM25(col) 单列（GaussVector 原生 BM25 不支持多列，实测 "does not support multicolumn indexes"；### 算子 + 内置 simple_cn_segmentation 中文分词）。BM25 仅支持 TEXT 列（不支持 VARCHAR，实测 "does not support data type character varying"），故 semantic_term.name(VARCHAR) 改走新增的 search_text_bm25(TEXT 生成列)；其余表已在 search_text_bm25(TEXT 生成列) 上建，直接复用 | P0-4/VERIFY-11/VERIFY-BM25-type/§4.4 |
-- | 7 | BM25 查询       | @@@ paradedb.match / paradedb.score()            | ### 算子（仅 DESC，HINT 非强制但推荐，仅对建了 BM25 索引的表列可用）—— 应用层 Adapter 实现，DDL 不涉及         | P0-4/§4.2 |
-- | 8 | trgm 索引       | USING gin (col gin_trgm_ops) 共 17 个            | 全部移除（GaussVector 不支持 pg_trgm/gin_trgm_ops；模糊匹配降级 ILIKE 粗召回 + 应用层 DefaultTrigramFallback 精排） | §2.3/§6 |
-- | 9 | gin(文本表达式) | idx_ke_edge_trgm_haystack: USING gin ((COALESCE...||...) gin_trgm_ops) | 移除（GaussVector 对 text 表达式无默认 gin opclass，实测 "data type text has no default operator class for access method gin"） | gsql 实测 VERIFY-4 |
-- | 10| 表存储引擎      | heap 默认                                        | 含 GIN 索引（tsvector/jsonb/数组）的表加 WITH (storage_type=astore)（D9：默认 Ustore 不支持 GIN）        | P0-9 M4/§4.1 |
-- | 11| tsvector regconfig | to_tsvector('simple', ...) 或 'zhcfg'        | to_tsvector('simple', ...) 保留 'simple'（GaussVector 无 'chinese' regconfig，M3；应用侧 tsvectorRecall 传 'simple'/'ngram'） | P0-9 M3 |
-- | 12| upsert 语法     | ON CONFLICT (key) DO UPDATE SET col=EXCLUDED.col | ON DUPLICATE KEY UPDATE col=VALUES(col)（应用层 Adapter 实现，DDL 不涉及；GaussVector 不支持 ON CONFLICT，M2/D8） | P0-6 M2 |
-- | 13| 列注释          | COMMENT ON COLUMN/TABLE                          | 完全保留（COMMENT ON 在 GaussVector 103.0.0 实测可用，VERIFY-1）                                       | gsql 实测 VERIFY-1 |
-- | 14| 外键 ON DELETE | REFERENCES ... ON DELETE CASCADE/RESTRICT        | 完全保留（实测 FK + ON DELETE CASCADE 可用，VERIFY-2）                                                | gsql 实测 VERIFY-2 |
-- | 15| 生成列          | GENERATED ALWAYS AS (...) STORED                | 完全保留（生成列检测走 information_schema.columns.generation_expression，M5；DDL 语法兼容）             | P0-8 M5 |
-- | 16| 部分索引        | CREATE INDEX ... WHERE col IS NOT NULL          | 完全保留（astore 表部分索引实测可用，VERIFY-3）                                                       | gsql 实测 VERIFY-3 |
-- ============================================================================

-- ============================================================================
-- JDBC 层契约（Phase 9 商业 GaussDB 驱动 smoke test 已确认，gsql 无法验证，不影响 DDL 可执行性）
-- ============================================================================
-- - JDBC 驱动加载：com.huawei.gaussdb.jdbc.Driver + jdbc:gaussdb:// （P0-7，✅ Phase 9 SPI + Class.forName 通过）
-- - 向量绑参稳定性：PreparedStatement.setString + CAST(? AS floatvector)（P0-5/B3，✅ Phase 9 dist 0.0/1.0/1.0；
--   注：GsDiskANN Index Scan 仍不被优化器选中，见 test-report §10.1，非驱动问题）
-- - createArrayOf / rs.getArray / setObject(UUID) 商业驱动兼容性（P0-6，✅ Phase 9 PgArray round-trip + setObject(UUID) 通过）
-- - DatabaseMetaData 覆盖度（UNIQUE/CHECK/反向外键/生成列）（P0-8，✅ Phase 9：PK/UNIQUE/CHECK 检出，生成列走 information_schema.columns.generation_expression）
-- - extra_float_digits 驱动默认值（向量 float 输出精度）
-- 详见 docs/test/gaussvector-backend-test-report.md §3。
