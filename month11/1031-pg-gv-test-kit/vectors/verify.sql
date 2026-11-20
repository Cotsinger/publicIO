-- 在服务实际使用的语义库执行。只查询，适用于 1031 的 PG / GV。
SELECT current_database() AS database_name, current_schema() AS schema_name;

-- 本体定义、实体类型、关系类型的 m3 覆盖率。
SELECT 'ontology_definition' AS item, COUNT(*) AS total,
       COUNT(CASE WHEN vector_norm(search_vector_m3) >= 1e-6 THEN 1 END) AS filled
FROM public.t_semantic_ontology_definition
UNION ALL
SELECT 'entity_type', COUNT(*),
       COUNT(CASE WHEN vector_norm(search_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_entity_type
UNION ALL
SELECT 'relation_type', COUNT(*),
       COUNT(CASE WHEN vector_norm(search_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_relation_type;

-- 语义目录 m3 覆盖率。只计 fill-vectors 的候选文本非空的行。
SELECT 'data_table' AS item, COUNT(*) AS total,
       COUNT(CASE WHEN vector_norm(table_description_vector_m3) >= 1e-6 THEN 1 END) AS filled
FROM public.t_semantic_data_table
WHERE length(trim(table_description)) > 0
UNION ALL
SELECT 'data_column', COUNT(*),
       COUNT(CASE WHEN vector_norm(column_description_short_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_data_column
WHERE length(trim(column_description_short)) > 0
UNION ALL
SELECT 'semantic_term', COUNT(*),
       COUNT(CASE WHEN vector_norm(term_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_term
WHERE length(trim(name || ' ' || coalesce(array_to_string(synonyms, ' '), ''))) > 0
UNION ALL
SELECT 'metric_instance', COUNT(*),
       COUNT(CASE WHEN vector_norm(metric_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_metric_instance
WHERE length(trim(coalesce(name, '') || ' ' || coalesce(metric_name, '') || ' '
             || coalesce(array_to_string(synonyms, ' '), '') || ' ' || coalesce(description, ''))) > 0
UNION ALL
SELECT 'column_value_description', COUNT(*),
       COUNT(CASE WHEN vector_norm(description_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_data_column_value
WHERE length(trim(coalesce(nullif(trim(description), ''), value))) > 0
UNION ALL
SELECT 'column_value_literal', COUNT(*),
       COUNT(CASE WHEN vector_norm(value_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_data_column_value
WHERE length(trim(value)) > 0
UNION ALL
SELECT 'sql_process', COUNT(*),
       COUNT(CASE WHEN vector_norm(query_vector_m3) >= 1e-6 THEN 1 END)
FROM public.t_semantic_sql_process
WHERE length(trim(coalesce(nullif(trim(query), ''), intent))) > 0;

-- C-04 的两个主题值。预期分别至少有一条，m3 范数接近 1。
SELECT value, table_name_en, column_name_en,
       round(vector_norm(value_vector_m3)::numeric, 4) AS m3_norm
FROM public.t_semantic_data_column_value
WHERE db_name_en = 'cordis_temporary'
  AND table_name_en = 'project_topics'
  AND column_name_en = 'topic'
  AND value IN ('FETOPEN-1-2014', 'FETOPEN-RIA-2014-2015')
ORDER BY value;
