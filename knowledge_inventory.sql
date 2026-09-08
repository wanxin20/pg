-- 知识库只读盘点：上传文件数量、实际分块数量、各文件索引明细和正文抽样。
-- 用法（内网服务器）：
-- psql -X -h /tmp -p 5433 -U haier_user -d haier_db -W -v ON_ERROR_STOP=1 -f "$HOME/pg/knowledge_inventory.sql"
-- 仅查询当前连接的数据库；不是升级脚本，不修改业务数据，不触发索引。
-- 全库管理员口径，不应用客户端的项目/个人文件可见性过滤。
-- 分块存在或有向量，不代表已通过应用层权限、质量和检索范围过滤。
-- 第 6 项每个现存文件抽取前 3 块，每块最多 1000 字符，不是全文导出。
-- 输出包含内部正文，请保存在受控位置，不要提交到公开 Git 仓库。
\set ON_ERROR_STOP on
\encoding UTF8
\pset pager off
\pset null '(NULL)'

-- 同一快照保证汇总和明细一致；超时防止在繁忙库上无限等待。
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '5s';

\echo '=== 1. 查询环境（确认连接的是内网 GOS 数据库） ==='
SELECT current_database() AS database_name,
       current_user AS database_user,
       now() AS snapshot_time,
       current_setting('transaction_read_only') AS read_only;

\echo '=== 2. 全库总量：上传文件与实际向量记录分别统计 ==='
SELECT
    (SELECT COUNT(*) FROM files) AS uploaded_files,
    (SELECT COUNT(*) FROM file_index_status WHERE status = 'completed') AS completed_index_files,
    (SELECT COUNT(*) FROM file_index_status WHERE status = 'failed') AS failed_index_files,
    COUNT(*) AS actual_chunks,
    COUNT(DISTINCT file_id) AS file_ids_with_chunks,
    COUNT(*) FILTER (WHERE embedding IS NOT NULL) AS chunks_with_vectors,
    COUNT(*) FILTER (WHERE embedding IS NULL) AS chunks_without_vectors,
    COUNT(*) FILTER (WHERE file_id IS NULL) AS chunks_without_file_id
FROM knowledge_embeddings;

\echo '=== 3. 全部上传文件的索引状态分布（包括未索引文件） ==='
SELECT COALESCE(s.status, 'not_indexed') AS index_status,
       COUNT(*) AS file_count
FROM files f
LEFT JOIN file_index_status s ON s.file_id = f.id
GROUP BY COALESCE(s.status, 'not_indexed')
ORDER BY file_count DESC, index_status;

\echo '=== 4. 各文件明细（含未索引及失败文件，按实际分块数降序） ==='
-- 先按文件聚合分块，再连接文件，避免联表后重复计数。
-- recorded_chunks 是状态表计数；actual_chunks 是实际分块表计数。
WITH chunk_counts AS (
    SELECT file_id,
           COUNT(*) AS actual_chunks,
           COUNT(*) FILTER (WHERE embedding IS NOT NULL) AS vector_chunks
    FROM knowledge_embeddings
    WHERE file_id IS NOT NULL
    GROUP BY file_id
)
SELECT p.name AS project_name,
       f.project_id,
       f.id AS file_id,
       f.name AS file_name,
       f.mime_type,
       f.size AS file_bytes,
       COALESCE(s.status, 'not_indexed') AS index_status,
       COALESCE(s.chunk_count, 0) AS recorded_chunks,
       COALESCE(c.actual_chunks, 0) AS actual_chunks,
       COALESCE(c.vector_chunks, 0) AS vector_chunks,
       COALESCE(s.chunk_count, 0) <> COALESCE(c.actual_chunks, 0) AS count_mismatch,
       s.error_message
FROM files f
LEFT JOIN projects p ON p.id = f.project_id
LEFT JOIN file_index_status s ON s.file_id = f.id
LEFT JOIN chunk_counts c ON c.file_id = f.id
ORDER BY actual_chunks DESC, f.project_id, f.name, f.id;

\echo '=== 5. 未关联现存文件的分块来源（可能包含记忆等非文件数据） ==='
-- 单独列出，避免将非文件知识记录遗漏，也不直接判定其为异常。
-- 内网旧基线的分块表没有 project_id，非文件来源不推断所属项目。
SELECT k.file_id,
       k.source_name,
       k.content_type,
       COUNT(*) AS actual_chunks,
       COUNT(*) FILTER (WHERE k.embedding IS NOT NULL) AS vector_chunks
FROM knowledge_embeddings k
LEFT JOIN files f ON f.id = k.file_id
WHERE f.id IS NULL
GROUP BY k.file_id, k.source_name, k.content_type
ORDER BY actual_chunks DESC, k.file_id, k.source_name;

\echo '=== 6. 文件正文抽样（每文件前 3 块，每块最多 1000 字符） ==='
-- 使用纵向显示避免长正文撑宽整张表；以真实文件关联项目，不依赖分块表 project_id。
-- chunk_index 可能重复，用主键排序保证抽样稳定；没有分块的文件见第 4 项。
\pset expanded on
WITH ranked_chunks AS (
    SELECT id,
           file_id,
           chunk_index,
           ROW_NUMBER() OVER (
               PARTITION BY file_id ORDER BY chunk_index NULLS LAST, id
           ) AS sample_rank
    FROM knowledge_embeddings
    WHERE file_id IS NOT NULL
)
SELECT p.name AS project_name,
       f.project_id,
       f.id AS file_id,
       f.name AS file_name,
       k.id AS chunk_id,
       k.chunk_index,
       k.content_type,
       k.embedding IS NOT NULL AS has_vector,
       CHAR_LENGTH(k.chunk_text) AS full_text_chars,
       COALESCE(CHAR_LENGTH(k.chunk_text), 0) > 1000 AS text_truncated,
       LEFT(k.chunk_text, 1000) AS text_sample
FROM ranked_chunks r
JOIN knowledge_embeddings k ON k.id = r.id
JOIN files f ON f.id = r.file_id
LEFT JOIN projects p ON p.id = f.project_id
WHERE r.sample_rank <= 3
ORDER BY f.project_id, f.name, f.id, r.sample_rank;
\pset expanded off

COMMIT;
\echo '=== 知识库只读盘点完成 ==='
