-- server_upgrade_063_to_065.sql —— 服务端 063 → 065 原子增量迁移。
--
-- 适用场景：内网 haier_db 已成功执行 server_upgrade_020_to_063.sql，
-- 需要补齐 064_structured_source_records.sql 与 065_jingzhun_streamable_http.sql。
-- 旧的 020 → 063 合并脚本是已发布制品，必须保持文件内容与 SHA-256 不变。
--
-- 执行要求：
--   1. 停止 Server 与数据层 Worker；
--   2. 先使用 pg_dump -Fc 备份数据库；
--   3. 使用 psql -f 执行本文件；
--   4. 最终必须看到 status=ok，且全程不得出现 ERROR。
--
-- 示例：
--   psql -h 127.0.0.1 -p 5433 -U haier_user -d haier_db \
--     -v ON_ERROR_STOP=1 -f server_upgrade_063_to_065.sql

\set ON_ERROR_STOP on

BEGIN;

-- ── 063 基线预检 ───────────────────────────────────────────────────────────
-- 不在旧库上“尽量执行”：基线不足时立即中止，避免得到部分升级的数据库。
DO $$
BEGIN
    IF to_regclass('public.system_config') IS NULL
       OR to_regclass('public.vendor_definitions') IS NULL
       OR to_regclass('public.agent_diagnostics') IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'users'
             AND column_name = 'token_version'
       )
    THEN
        RAISE EXCEPTION '063 基线预检失败：缺少 063 终态表或字段，请先执行 server_upgrade_020_to_063.sql';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.system_config WHERE key = 'llm_gateway'
    ) THEN
        RAISE EXCEPTION '063 基线预检失败：缺少 system_config.llm_gateway';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.vendor_definitions WHERE vendor_slug = 'jingzhun'
    ) THEN
        RAISE EXCEPTION '063 基线预检失败：缺少 vendor_definitions.jingzhun';
    END IF;
END
$$;

-- ── 064 · 全局共享的来源结构化记录 ────────────────────────────────────────
-- 结构化采集数据不进入向量知识库，也不再进入已停用的 dl_* 图谱链路。
-- 表中故意不设置 project_id / organization_id：所有合法用户共享同一份数据，
-- 来源业务 ID 或完整载荷指纹负责幂等，重复上传只更新发生变化的记录。
CREATE TABLE IF NOT EXISTS public.structured_source_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source VARCHAR(100) NOT NULL,
    record_type VARCHAR(100) NOT NULL,
    record_key CHAR(64) NOT NULL,
    source_object_id TEXT,
    title VARCHAR(500) NOT NULL DEFAULT '',
    payload JSONB NOT NULL,
    search_text TEXT NOT NULL DEFAULT '',
    content_sha256 CHAR(64) NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_structured_source_record UNIQUE (source, record_key)
);

CREATE INDEX IF NOT EXISTS ix_structured_source_records_source_type
    ON public.structured_source_records (source, record_type);

CREATE INDEX IF NOT EXISTS ix_structured_source_records_updated_at
    ON public.structured_source_records (updated_at DESC);

-- ── 065 · 鲸准 MCP 切换为 Streamable HTTP ─────────────────────────────────
-- 保留管理员已经配置的自定义 URL；只统一协议字段并移除旧 sse_url 别名。
-- 通过 IS DISTINCT FROM 避免重复执行时无意义地刷新 updated_at。
WITH normalized AS (
    SELECT
        vendor_slug,
        'MCP Streamable HTTP,4 个 ES tool'::VARCHAR(512) AS description,
        (config - 'sse_url' - 'transport' - 'url')
            || jsonb_build_object(
                'transport', 'streamable_http',
                'url', COALESCE(
                    NULLIF(config->>'url', ''),
                    NULLIF(config->>'sse_url', ''),
                    'https://mcp.jingdata.com/sse'
                )
            ) AS config
    FROM public.vendor_definitions
    WHERE vendor_slug = 'jingzhun'
)
UPDATE public.vendor_definitions AS target
SET
    description = normalized.description,
    config = normalized.config,
    updated_at = now()
FROM normalized
WHERE target.vendor_slug = normalized.vendor_slug
  AND (
      target.description IS DISTINCT FROM normalized.description
      OR target.config IS DISTINCT FROM normalized.config
  );

-- ── 提交前终态校验 ─────────────────────────────────────────────────────────
-- 任一对象或配置不符合 065 终态都会抛错，使整个事务回滚。
DO $$
DECLARE
    jingzhun_config JSONB;
BEGIN
    IF to_regclass('public.structured_source_records') IS NULL
       OR to_regclass('public.ix_structured_source_records_source_type') IS NULL
       OR to_regclass('public.ix_structured_source_records_updated_at') IS NULL
    THEN
        RAISE EXCEPTION '064 终态校验失败：structured_source_records 表或索引缺失';
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
        RAISE EXCEPTION '065 终态校验失败：鲸准 MCP 配置未统一为 Streamable HTTP：%', jingzhun_config;
    END IF;
END
$$;

COMMIT;

-- 提交后只读摘要：应返回一行，status=ok。
SELECT
    'ok' AS status,
    current_database() AS database_name,
    to_regclass('public.structured_source_records') AS structured_table,
    config->>'transport' AS jingzhun_transport,
    config->>'url' AS jingzhun_url
FROM public.vendor_definitions
WHERE vendor_slug = 'jingzhun';
