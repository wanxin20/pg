-- server_upgrade_071_to_074.sql —— GOS 服务端 071 → 074 原子增量迁移。
-- 适用：目标库已完成 066 → 071；仅补齐 072 诊断字段及 074 本地密码策略。
-- 按部署要求跳过 073；本脚本不读取或修改子任务并发配置。
-- 原始迁移来自应用仓库提交 5f2993bb；下方 SOURCE 段保持原文。
-- 执行前停止 GOS Server 与相关写入进程，并使用 pg_dump -Fc 备份实际业务库。
-- 使用 psql -v ON_ERROR_STOP=1 -f server_upgrade_071_to_074.sql 整体执行。
-- 已执行 072 或 074 的库可重跑；不更改现有密码哈希，不停用账号。
-- 升级后旧本地账号可能需要改密，闲置停用由应用策略执行；SSO 密码仍由上游管理。

\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL search_path = public;

-- 阻止在空库或缺少前置结构的库中误执行。
DO $$
BEGIN
    IF to_regclass('public.users') IS NULL
       OR to_regclass('public.audit_logs') IS NULL
       OR to_regclass('public.agent_diagnostics') IS NULL
       OR to_regclass('public.due_diligence_cases') IS NULL
       OR to_regclass('public.due_diligence_events') IS NULL
    THEN
        RAISE EXCEPTION '071 基线预检失败：缺少前置表，请先完成此前升级';
    END IF;
END
$$;

-- ===== BEGIN SOURCE 072_diagnostic_context.sql =====
-- 诊断关联编号、构建身份和白名单上下文；兼容旧客户端上传。
ALTER TABLE agent_diagnostics ADD COLUMN IF NOT EXISTS request_id varchar(36);
ALTER TABLE agent_diagnostics ADD COLUMN IF NOT EXISTS build varchar(64);
ALTER TABLE agent_diagnostics ADD COLUMN IF NOT EXISTS context jsonb;
CREATE INDEX IF NOT EXISTS ix_agent_diagnostics_request_id ON agent_diagnostics(request_id);
CREATE INDEX IF NOT EXISTS ix_agent_diagnostics_created_at ON agent_diagnostics(created_at);
-- 验证：SELECT request_id, build, context FROM agent_diagnostics LIMIT 1;
-- ===== END SOURCE 072_diagnostic_context.sql =====

-- ===== BEGIN SOURCE 074_local_password_policy.sql =====
-- 本地账号密码与闲置生命周期。发布代码前执行；不修改任何现有密码哈希。
ALTER TABLE users ADD COLUMN IF NOT EXISTS failed_login_window_start TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_changed_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_policy_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS reactivated_at TIMESTAMPTZ;

-- 恢复本地和两个 SSO 入口的历史成功登录时间；失败日志不计入。
-- 仅回填空值或更旧的值，重复执行不能覆盖上线后的新登录记录。
UPDATE users AS u SET last_login_at = a.last_login_at
FROM (SELECT user_id, MAX(created_at) AS last_login_at FROM audit_logs
      WHERE action IN ('LOGIN_SUCCESS', 'SSO_LOGIN_SUCCESS', 'SSO_PASSWORD_LOGIN_SUCCESS')
        AND user_id IS NOT NULL GROUP BY user_id) AS a
WHERE u.id = a.user_id AND (u.last_login_at IS NULL OR u.last_login_at < a.last_login_at);

-- 验证：SELECT username, auth_source, password_policy_version, last_login_at FROM users;
-- ===== END SOURCE 074_local_password_policy.sql =====

-- 提交前检查所有新增字段的类型和密码策略默认状态；失败则整体回滚。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM (VALUES
            ('agent_diagnostics', 'request_id', 'character varying'),
            ('agent_diagnostics', 'build', 'character varying'),
            ('agent_diagnostics', 'context', 'jsonb'),
            ('users', 'failed_login_window_start', 'timestamp with time zone'),
            ('users', 'password_changed_at', 'timestamp with time zone'),
            ('users', 'password_policy_version', 'integer'),
            ('users', 'must_change_password', 'boolean'),
            ('users', 'last_login_at', 'timestamp with time zone'),
            ('users', 'reactivated_at', 'timestamp with time zone')
        ) AS expected(table_name, column_name, data_type)
        LEFT JOIN information_schema.columns AS c
          ON c.table_schema = 'public' AND c.table_name = expected.table_name
         AND c.column_name = expected.column_name
        WHERE c.data_type IS DISTINCT FROM expected.data_type
    ) THEN
        RAISE EXCEPTION '072/074 终态校验失败：新增字段缺失或类型不符';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users'
          AND is_nullable = 'NO'
          AND ((column_name = 'password_policy_version' AND column_default = '0')
            OR (column_name = 'must_change_password' AND column_default = 'true'))) <> 2
    THEN
        RAISE EXCEPTION '074 终态校验失败：密码策略字段约束或默认值不符';
    END IF;
    IF to_regclass('public.ix_agent_diagnostics_request_id') IS NULL
       OR to_regclass('public.ix_agent_diagnostics_created_at') IS NULL
    THEN
        RAISE EXCEPTION '072 终态校验失败：诊断索引缺失';
    END IF;
END
$$;

COMMIT;

-- 提交后只返回结构摘要，不输出账号数据、密码哈希或连接凭据。
SELECT 'ok' AS status, current_database() AS database_name,
       '074' AS migration_target, '072,074' AS included_migrations;
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'users'
  AND column_name IN ('failed_login_window_start', 'password_changed_at',
      'password_policy_version', 'must_change_password', 'last_login_at', 'reactivated_at')
ORDER BY column_name;
