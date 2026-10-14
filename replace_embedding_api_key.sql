-- 更换 GOS 知识库向量模型 Key；不修改模型、接口地址、维度或现有索引。
-- 使用 psql -X -W -f replace_embedding_api_key.sql，并指定实际连接参数。
-- 连接后按提示粘贴新 Key；不要把真实 Key 写进本文件或 Git。
-- 成功返回 status=ok；配置按请求读取，无需重启或重建知识库。
\set ON_ERROR_STOP on
\set ECHO none
\set VERBOSITY terse
\encoding UTF8
\pset pager off

\if :{?embedding_api_key}
\else
  \prompt 'New embedding API Key: ' embedding_api_key
\endif

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '30s';

-- 通过 psql 的 SQL 字面量引用安全传参，不拼接到 DO 代码中；不回显参数值。
SELECT set_config('gos.new_embedding_api_key', :'embedding_api_key', true) AS private_value
\gset
\unset embedding_api_key
\unset private_value

DO $$
DECLARE
    new_key text := btrim(current_setting('gos.new_embedding_api_key'), E' \t\r\n');
    old_config jsonb;
BEGIN
    IF new_key !~ '^sk-[A-Za-z0-9_-]{16,}$' THEN
        RAISE EXCEPTION '新 Key 格式无效：请粘贴完整的 sk- 开头 API Key';
    END IF;

    SELECT value INTO old_config
    FROM public.system_config
    WHERE key = 'embedding_model'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '未找到 embedding_model 配置，请核对连接的数据库；未作修改';
    END IF;
    IF jsonb_typeof(old_config) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'embedding_model 不是有效 JSON 对象；未作修改';
    END IF;

    UPDATE public.system_config
    SET value = jsonb_set(old_config, '{api_key}', to_jsonb(new_key), true),
        updated_at = now()
    WHERE key = 'embedding_model';
END
$$;

COMMIT;

-- 只显示配置状态，不显示完整 Key、尾号或其它凭据。
SELECT 'ok' AS status,
       current_database() AS database_name,
       value->>'model' AS embedding_model,
       value->>'dimension' AS dimension,
       length(coalesce(value->>'api_key', '')) > 0 AS key_configured
FROM public.system_config
WHERE key = 'embedding_model';
