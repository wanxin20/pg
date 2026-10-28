\set ON_ERROR_STOP on
-- 076：增加第二位 SSO 超级管理员 A1016659 / A1016659@haier.com。
-- 在 075 完成后执行；不替换 01069355，不创建账号，不修改其他账号或业务关联。
BEGIN;
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

-- 验证：两行均应为 iama / super_admin / active；目标用户需要重新 SSO 登录。
SELECT username, email, auth_source, role, status FROM users
WHERE username IN ('01069355', 'A1016659') ORDER BY username;
