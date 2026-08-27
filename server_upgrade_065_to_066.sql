-- server_upgrade_065_to_066.sql —— 服务端 065 → 066 原子增量迁移。
--
-- 适用场景：内网 haier_db 已成功执行 server_upgrade_063_to_065.sql，
-- 需要补齐 066_agent_runtime_config.sql，为客户端下发子智能体并发上限。
-- 已发布的旧迁移脚本保持不变，本文件可安全重复执行。
--
-- 执行要求：
--   1. 停止 Server 与数据层 Worker；
--   2. 先使用 pg_dump -Fc 备份数据库；
--   3. 使用 psql -f 执行本文件；
--   4. 最终必须看到 status=ok，且全程不得出现 ERROR。
--
-- 示例：
--   psql -h 127.0.0.1 -p 5433 -U haier_user -d haier_db \
--     -v ON_ERROR_STOP=1 -f server_upgrade_065_to_066.sql

\set ON_ERROR_STOP on

BEGIN;

-- ── 065 基线预检 ───────────────────────────────────────────────────────────
-- 基线不足时立即中止，避免在未完成 064/065 迁移的数据库上继续升级。
DO $$
DECLARE
    jingzhun_config JSONB;
BEGIN
    IF to_regclass('public.system_config') IS NULL
       OR to_regclass('public.vendor_definitions') IS NULL
       OR to_regclass('public.structured_source_records') IS NULL
    THEN
        RAISE EXCEPTION '065 基线预检失败：缺少 065 终态表，请先执行 server_upgrade_063_to_065.sql';
    END IF;

    SELECT config
    INTO jingzhun_config
    FROM public.vendor_definitions
    WHERE vendor_slug = 'jingzhun';

    IF jingzhun_config IS NULL
       OR jingzhun_config->>'transport' IS DISTINCT FROM 'streamable_http'
       OR NULLIF(jingzhun_config->>'url', '') IS NULL
       OR jingzhun_config ? 'sse_url'
    THEN
        RAISE EXCEPTION '065 基线预检失败：鲸准 MCP 配置未统一为 Streamable HTTP：%', jingzhun_config;
    END IF;
END
$$;

-- ── 066 · 客户端智能体运行参数 ─────────────────────────────────────────────
-- 子智能体并发由服务端 system_config 统一下发。首次迁移默认限制为 2；
-- 重复执行时保留管理员已经设置的 max_concurrent_subagents 值。
INSERT INTO public.system_config (id, key, value, description, category)
VALUES (
    gen_random_uuid(),
    'agent_runtime',
    '{"max_concurrent_subagents": 2}'::jsonb,
    '智能体运行参数：max_concurrent_subagents 为单个智能体同时运行的直接子智能体上限（1-64）',
    'client'
)
ON CONFLICT (key) DO UPDATE
SET value = jsonb_set(
        COALESCE(system_config.value, '{}'::jsonb),
        '{max_concurrent_subagents}',
        COALESCE(
            system_config.value -> 'max_concurrent_subagents',
            '2'::jsonb
        ),
        true
    ),
    description = EXCLUDED.description,
    category = EXCLUDED.category,
    updated_at = NOW();

-- ── 提交前终态校验 ─────────────────────────────────────────────────────────
-- 任一配置不符合 066 终态都会抛错，使整个事务回滚。
DO $$
DECLARE
    runtime_config JSONB;
    runtime_category TEXT;
    concurrency_limit NUMERIC;
BEGIN
    SELECT value, category
    INTO runtime_config, runtime_category
    FROM public.system_config
    WHERE key = 'agent_runtime';

    IF runtime_config IS NULL
       OR jsonb_typeof(runtime_config) IS DISTINCT FROM 'object'
       OR runtime_category IS DISTINCT FROM 'client'
    THEN
        RAISE EXCEPTION '066 终态校验失败：agent_runtime 配置缺失或分类错误：value=%, category=%',
            runtime_config, runtime_category;
    END IF;

    IF jsonb_typeof(runtime_config->'max_concurrent_subagents') IS DISTINCT FROM 'number'
    THEN
        RAISE EXCEPTION '066 终态校验失败：max_concurrent_subagents 必须是数字：%', runtime_config;
    END IF;

    concurrency_limit := (runtime_config->>'max_concurrent_subagents')::NUMERIC;
    IF concurrency_limit <> trunc(concurrency_limit)
       OR concurrency_limit < 1
       OR concurrency_limit > 64
    THEN
        RAISE EXCEPTION '066 终态校验失败：max_concurrent_subagents 必须是 1-64 的整数：%', concurrency_limit;
    END IF;
END
$$;

COMMIT;

-- 提交后只读摘要：应返回一行，status=ok。
SELECT
    'ok' AS status,
    current_database() AS database_name,
    key,
    value->>'max_concurrent_subagents' AS max_concurrent_subagents,
    category
FROM public.system_config
WHERE key = 'agent_runtime';
