-- server_upgrade_066_to_071.sql —— GOS 服务端 066 → 071 原子增量迁移。
--
-- 适用：目标库已完成 065 → 066，尚需补齐 067–071。
-- 按 GOS 原始迁移文件的顺序执行；068、069 的独立事务边界并入本脚本的单一事务。
-- 可在失败回滚后重跑；成功后重跑也应保持幂等。历史事件和快照保留。
--
-- 执行前停止 GOS Server 与相关写入进程，使用 pg_dump -Fc 备份目标数据库。
-- 使用 psql -v ON_ERROR_STOP=1 -f server_upgrade_066_to_071.sql 整体执行。
-- 本文件与逐个执行 067–071 原始脚本二选一，不要逐段选中执行。

\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '10s';

-- 066 基线预检：目标库必须已有客户端运行配置和项目成员模型。
DO $$
BEGIN
    IF to_regclass('public.system_config') IS NULL
       OR to_regclass('public.users') IS NULL
       OR to_regclass('public.projects') IS NULL
       OR to_regclass('public.project_members') IS NULL
    THEN
        RAISE EXCEPTION '066 基线预检失败：缺少 GOS 核心表';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.system_config
        WHERE key = 'agent_runtime'
          AND category = 'client'
          AND jsonb_typeof(value->'max_concurrent_subagents') = 'number'
    ) THEN
        RAISE EXCEPTION '066 基线预检失败：缺少有效 agent_runtime 并发配置';
    END IF;
END
$$;
-- ===== BEGIN SOURCE 067_agent_output_tokens_config.sql =====
-- 067: 客户端智能体最大输出 Token 动态配置
--
-- max_output_tokens 默认为 JSON null，表示不覆盖客户端内核默认值（8192）。
-- 管理员填写后，客户端沿用 agent_runtime 的短 TTL 同步链路，在后续推理轮次
-- 注入 CLAUDE_CODE_MAX_OUTPUT_TOKENS，无需重新发布或重启客户端。

INSERT INTO system_config (id, key, value, description, category)
VALUES (
    gen_random_uuid(),
    'agent_runtime',
    '{"max_concurrent_subagents": 2, "max_output_tokens": null}'::jsonb,
    '智能体运行参数：子智能体并发上限（1-64）；最大输出 Token 留空时使用客户端默认值 8192，填写后覆盖客户端默认值（1-64000）',
    'client'
)
ON CONFLICT (key) DO UPDATE
SET value = jsonb_set(
        COALESCE(system_config.value, '{}'::jsonb),
        '{max_output_tokens}',
        COALESCE(
            system_config.value -> 'max_output_tokens',
            'null'::jsonb
        ),
        true
    ),
    description = EXCLUDED.description,
    category = EXCLUDED.category,
    updated_at = NOW();

-- 验证：
-- SELECT key, value -> 'max_output_tokens', category
-- FROM system_config WHERE key = 'agent_runtime';
-- ===== END SOURCE 067_agent_output_tokens_config.sql =====

-- ===== BEGIN SOURCE 068_due_diligence.sql =====
-- GOS 正式尽调台账。沿用 projects、files、users；不依赖本体实验。
CREATE TABLE IF NOT EXISTS due_diligence_cases (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 project_id UUID NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,
 version INTEGER NOT NULL DEFAULT 0,
 state JSONB NOT NULL DEFAULT '{}',
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS due_diligence_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
 request_id UUID NOT NULL,
 actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
 action VARCHAR(32) NOT NULL,
 version INTEGER NOT NULL,
 payload JSONB NOT NULL,
 snapshot JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(project_id, request_id)
);
CREATE INDEX IF NOT EXISTS ix_due_diligence_events_project_id ON due_diligence_events(project_id);
-- 验证：SELECT project_id, version FROM due_diligence_cases;
-- 验证：SELECT project_id, action, version, created_at FROM due_diligence_events ORDER BY created_at DESC LIMIT 20;
-- ===== END SOURCE 068_due_diligence.sql =====

-- ===== BEGIN SOURCE 069_unify_project_lead.sql =====
-- 项目负责人就是项目组长。修复历史表单负责人和创建者 owner 分离的数据。
-- 已登记的有效账户优先；没有有效登记时沿用原 owner。个人空间和系统知识库不参与转交。
-- 不改全局用户角色、尽调负责人或专业分工。重复执行不会重复添加成员。
LOCK TABLE projects, project_members IN SHARE ROW EXCLUSIVE MODE;

-- 历史创建者即使缺失成员行也保留项目访问权，后续统一降为普通成员。
INSERT INTO project_members (id, project_id, user_id, role)
SELECT gen_random_uuid(), p.id, p.owner_id, 'member'
FROM projects p JOIN users u ON u.id = p.owner_id
WHERE NOT p.is_default AND u.role <> 'system'
ON CONFLICT (project_id, user_id) DO NOTHING;

WITH resolved AS (
    SELECT p.id, coalesce(lead.id, old_owner.id) AS lead_id,
           coalesce(lead.display_name, lead.username, old_owner.display_name, old_owner.username) AS lead_name
    FROM projects p
    LEFT JOIN users lead ON lead.id::text = p.settings #>> '{basic_info,project_lead_id}'
        AND lead.role <> 'system' AND lead.status = 'active'
    LEFT JOIN users old_owner ON old_owner.id = p.owner_id AND old_owner.role <> 'system'
    WHERE NOT p.is_default
        AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p.owner_id AND u.role = 'system')
), normalized AS (
    SELECT p.id, r.lead_id,
        (CASE WHEN jsonb_typeof(p.settings) = 'object' THEN p.settings ELSE '{}'::jsonb END)
        || jsonb_build_object('basic_info',
            (CASE WHEN jsonb_typeof(p.settings->'basic_info') = 'object' THEN p.settings->'basic_info' ELSE '{}'::jsonb END)
            || jsonb_build_object('project_lead_id', r.lead_id::text, 'project_lead_name', r.lead_name)) AS settings
    FROM projects p JOIN resolved r ON p.id = r.id WHERE r.lead_id IS NOT NULL
)
UPDATE projects p SET owner_id = n.lead_id, settings = n.settings, updated_at = now()
FROM normalized n WHERE p.id = n.id
    AND (p.owner_id IS DISTINCT FROM n.lead_id OR p.settings IS DISTINCT FROM n.settings);

UPDATE project_members m SET role = 'member'
FROM projects p WHERE m.project_id = p.id AND NOT p.is_default
    AND p.owner_id IS NOT NULL AND m.user_id <> p.owner_id AND m.role = 'owner'
    AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p.owner_id AND u.role = 'system');

INSERT INTO project_members (id, project_id, user_id, role)
SELECT gen_random_uuid(), p.id, p.owner_id, 'owner'
FROM projects p JOIN users u ON u.id = p.owner_id
WHERE NOT p.is_default AND u.role <> 'system'
ON CONFLICT (project_id, user_id) DO UPDATE SET role = EXCLUDED.role
WHERE project_members.role IS DISTINCT FROM EXCLUDED.role;

-- 验证：业务项目的 owner、表单负责人和唯一 owner 成员应一致（无负责人历史孤儿项目需人工处理）。
-- SELECT p.id, p.name FROM projects p JOIN users u ON u.id=p.owner_id WHERE NOT p.is_default AND u.role<>'system' AND
-- (p.owner_id::text IS DISTINCT FROM p.settings #>> '{basic_info,project_lead_id}' OR
--  (SELECT count(*) FROM project_members m WHERE m.project_id=p.id AND m.role='owner' AND m.user_id=p.owner_id) <> 1);
-- ===== END SOURCE 069_unify_project_lead.sql =====

-- ===== BEGIN SOURCE 070_remove_duplicate_project_lead.sql =====
-- 项目组长统一使用 projects.owner_id，姓名由关联用户生成，不再存第二份负责人。
-- 此迁移仅删除冗余字段，不修改当前组长、成员角色或尽调分工，可重复执行。
UPDATE projects
SET settings = settings #- '{basic_info,project_lead_id}' #- '{basic_info,project_lead_name}',
    updated_at = now()
WHERE jsonb_typeof(settings->'basic_info') = 'object'
    AND (settings->'basic_info' ? 'project_lead_id' OR settings->'basic_info' ? 'project_lead_name');

-- 验证：应为 0。
-- SELECT count(*) FROM projects WHERE settings->'basic_info' ?| array['project_lead_id','project_lead_name'];
-- ===== END SOURCE 070_remove_duplicate_project_lead.sql =====

-- ===== BEGIN SOURCE 071_derive_dd_lead_from_project_owner.sql =====
-- 尽调统筹统一由项目组长担任；活跃台账不再单独保存负责人。
-- 历史事件/快照保留当时事实；专业分工、审批链和项目组长不作修改。
UPDATE due_diligence_cases
SET state = state #- '{config,lead_id}'
WHERE jsonb_typeof(state->'config') = 'object' AND state->'config' ? 'lead_id';

-- 验证：应为 0。
-- SELECT count(*) FROM due_diligence_cases WHERE state->'config' ? 'lead_id';
-- ===== END SOURCE 071_derive_dd_lead_from_project_owner.sql =====

-- 提交前校验：任一终态缺失则回滚整个升级。
DO $$
BEGIN
    IF to_regclass('public.due_diligence_cases') IS NULL
       OR to_regclass('public.due_diligence_events') IS NULL
       OR to_regclass('public.ix_due_diligence_events_project_id') IS NULL
    THEN
        RAISE EXCEPTION '068 终态校验失败：尽调台账或索引缺失';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.system_config
        WHERE key = 'agent_runtime'
          AND category = 'client'
          AND value ? 'max_output_tokens'
    ) THEN
        RAISE EXCEPTION '067 终态校验失败：max_output_tokens 配置缺失';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.projects
        WHERE jsonb_typeof(settings->'basic_info') = 'object'
          AND settings->'basic_info' ?| ARRAY['project_lead_id', 'project_lead_name']
    ) THEN
        RAISE EXCEPTION '070 终态校验失败：项目中仍有冗余组长字段';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.due_diligence_cases
        WHERE state->'config' ? 'lead_id'
    ) THEN
        RAISE EXCEPTION '071 终态校验失败：活跃尽调台账中仍有独立负责人';
    END IF;
END
$$;

COMMIT;

-- 提交后只读摘要：应返回一行 status=ok。
SELECT 'ok' AS status,
       current_database() AS database_name,
       to_regclass('public.due_diligence_cases') AS due_diligence_cases,
       to_regclass('public.due_diligence_events') AS due_diligence_events,
       value->'max_output_tokens' AS max_output_tokens
FROM public.system_config
WHERE key = 'agent_runtime';
