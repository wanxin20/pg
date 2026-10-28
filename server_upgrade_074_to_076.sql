\set ON_ERROR_STOP on
-- 074 → 076 合并升级：一次设置两位 SSO 超级管理员并退役本地人员账号。
-- 适用于已完成 074、075 或 076 的目标 GOS 业务库；可重复执行。
-- 执行前备份业务库并停止服务写入。全部操作在同一事务内，任一步失败全部回滚。
-- 不执行 073，不调整并发配置，不删除历史用户或业务关联。
BEGIN;
-- 合并来源：server_upgrade_074_to_075.sql
SET LOCAL lock_timeout = '10s';
SET LOCAL search_path = public;
LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE;

-- 必须先核对目标身份；目标不存在、停用或未绑定 SSO 时整笔回滚，禁止先停旧账号。
DO $$
BEGIN
    IF (SELECT count(*) FROM users
        WHERE username = '01069355' AND lower(email) = 'liupw@haier.com'
          AND auth_source = 'iama' AND status = 'active'
          AND role <> 'system' AND nullif(trim(iama_user_id), '') IS NOT NULL) <> 1
    THEN
        RAISE EXCEPTION 'SSO 管理员切换中止：请核对 01069355 / liupw@haier.com 已通过 IAMA 登录且账号正常';
    END IF;
END
$$;

WITH promoted AS (
    UPDATE users
    SET role = 'super_admin', token_version = token_version + 1, updated_at = now()
    WHERE username = '01069355' AND lower(email) = 'liupw@haier.com'
      AND auth_source = 'iama' AND status = 'active' AND role <> 'super_admin'
    RETURNING id, username
)
INSERT INTO audit_logs (id, user_id, action, resource_type, resource_id, detail, created_at)
SELECT gen_random_uuid(), id, 'SSO_ADMIN_PROMOTED', 'users', id::text,
       jsonb_build_object('username', username, 'migration', '075', 'role', 'super_admin'), now()
FROM promoted;

-- 所有本地人员账号停用并降为普通历史账号；占位系统账号不参与人员切换。
-- 仅在状态确实变化时撤销令牌和写审计，重跑不会重复撤销或追加相同事件。
WITH retired AS (
    UPDATE users
    SET status = 'disabled', role = 'user', password_hash = '',
        token_version = token_version + 1,
        must_change_password = false, failed_login_attempts = 0,
        failed_login_window_start = NULL, locked_until = NULL,
        iama_access_token = NULL, updated_at = now()
    WHERE auth_source = 'local' AND role <> 'system'
      AND (status <> 'disabled' OR role <> 'user' OR password_hash <> ''
           OR must_change_password OR failed_login_attempts <> 0
           OR failed_login_window_start IS NOT NULL OR locked_until IS NOT NULL
           OR iama_access_token IS NOT NULL)
    RETURNING id, username
)
INSERT INTO audit_logs (id, user_id, action, resource_type, resource_id, detail, created_at)
SELECT gen_random_uuid(), id, 'LOCAL_AUTH_RETIRED', 'users', id::text,
       jsonb_build_object('username', username, 'migration', '075',
                          'reason', 'SSO-only; historical references retained'), now()
FROM retired;

-- 已关联的 SSO 用户不再保存任何旧本地密码；本地口令状态不应影响上游认证。
UPDATE users
SET password_hash = '', must_change_password = false, updated_at = now()
WHERE auth_source = 'iama' AND (password_hash <> '' OR must_change_password);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE username = '01069355'
        AND lower(email) = 'liupw@haier.com' AND auth_source = 'iama'
        AND role = 'super_admin' AND status = 'active')
       OR EXISTS (SELECT 1 FROM users WHERE auth_source = 'local' AND role <> 'system'
          AND (status <> 'disabled' OR password_hash <> '' OR role <> 'user'))
    THEN
        RAISE EXCEPTION '075 终态校验失败，管理员切换和本地账号停用已回滚';
    END IF;
END
$$;

-- 合并来源：server_upgrade_075_to_076.sql
SET LOCAL lock_timeout = '10s';
SET LOCAL search_path = public;
LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE;

-- 同时校验既有管理员和新管理员身份，避免顺序错误或给同名本地账号提权。
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE username = '01069355'
        AND lower(email) = 'liupw@haier.com' AND auth_source = 'iama'
        AND role = 'super_admin' AND status = 'active'
        AND nullif(trim(iama_user_id), '') IS NOT NULL)
    THEN
        RAISE EXCEPTION '076 中止：请先完成 075，确认 01069355 为正常的 SSO 超级管理员';
    END IF;
    IF (SELECT count(*) FROM users WHERE username = 'A1016659'
        AND lower(email) = 'a1016659@haier.com' AND auth_source = 'iama'
        AND status = 'active' AND role <> 'system'
        AND nullif(trim(iama_user_id), '') IS NOT NULL) <> 1
    THEN
        RAISE EXCEPTION '076 中止：请核对 A1016659 / A1016659@haier.com 已绑定 IAMA 且账号正常';
    END IF;
END
$$;

-- 仅首次提权撤销旧会话并记录审计；重复执行不改变 token_version 或重复写日志。
WITH promoted AS (
    UPDATE users
    SET role = 'super_admin', token_version = token_version + 1, updated_at = now()
    WHERE username = 'A1016659' AND lower(email) = 'a1016659@haier.com'
      AND auth_source = 'iama' AND status = 'active' AND role <> 'super_admin'
    RETURNING id, username
)
INSERT INTO audit_logs (id, user_id, action, resource_type, resource_id, detail, created_at)
SELECT gen_random_uuid(), id, 'SSO_ADMIN_PROMOTED', 'users', id::text,
       jsonb_build_object('username', username, 'migration', '076', 'role', 'super_admin'), now()
FROM promoted;
COMMIT;

-- 验证：两人均应为 iama / super_admin / active，本地可用人员账号数应为 0。
SELECT username, email, auth_source, role, status FROM users
WHERE username IN ('01069355', 'A1016659') ORDER BY username;
SELECT count(*) AS remaining_active_local_users FROM users
WHERE auth_source = 'local' AND role <> 'system' AND status = 'active';
