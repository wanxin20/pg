-- =============================================================================
-- 迁移脚本 002: 协议对齐 + 安全修复 + 数据完整性
-- 对应方案文档: 架构文档/05-后台接口与管理系统实现方案.md
-- 执行前请备份数据库！
-- =============================================================================

-- ── Step 0: 角色模型迁移 ─────────────────────────────────────────

-- 将旧角色值迁移到新角色值
UPDATE users SET role = 'admin' WHERE role = 'reviewer';
UPDATE users SET role = 'user' WHERE role = 'viewer';
-- 如需 super_admin，手动指定：
-- UPDATE users SET role = 'super_admin' WHERE username = 'your_admin_username';

-- ── Step 0: 项目阶段迁移 ─────────────────────────────────────────

-- 将旧阶段值迁移到新业务阶段值
UPDATE projects SET stage = 'research' WHERE stage = 'draft';
UPDATE projects SET stage = 'research' WHERE stage = 'active';
UPDATE projects SET stage = 'investment_review' WHERE stage = 'review';
UPDATE projects SET stage = 'post_investment' WHERE stage = 'completed';
UPDATE projects SET stage = 'post_investment' WHERE stage = 'archived';

-- 修改默认值
ALTER TABLE projects ALTER COLUMN stage SET DEFAULT 'research';

-- ── Step 1: 新增字段 ────────────────────────────────────────────

-- conversations 表加 user_id（数据隔离）
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_conversations_user ON conversations(user_id);

-- projects 表加 priority
ALTER TABLE projects ADD COLUMN IF NOT EXISTS priority VARCHAR(16) DEFAULT 'medium';

-- announcements 表补齐列（ORM 中使用但建表 DDL 中可能缺失）
ALTER TABLE announcements ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true;
ALTER TABLE announcements ADD COLUMN IF NOT EXISTS category VARCHAR(32) DEFAULT 'info';

-- ── Step 1: 缺失索引 ────────────────────────────────────────────

-- memories 联合唯一索引（防止 sync push 产生重复）
CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_unique_key
    ON memories(project_id, user_id, key);

-- ── Step 1: 外键级联策略修复 ─────────────────────────────────────

-- 删除用户不应级联删除项目，改为置空 owner_id
ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_owner_id_fkey;
ALTER TABLE projects ADD CONSTRAINT projects_owner_id_fkey
    FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL;

-- 修改 owner_id 允许 NULL（SET NULL 需要列可空）
ALTER TABLE projects ALTER COLUMN owner_id DROP NOT NULL;

-- ── pgvector 向量列 ──────────────────────────────────────────────

ALTER TABLE knowledge_embeddings ADD COLUMN IF NOT EXISTS embedding vector(1024);
CREATE INDEX IF NOT EXISTS idx_knowledge_embedding
    ON knowledge_embeddings USING hnsw (embedding vector_cosine_ops);

-- =============================================================================
-- 完成。请验证：
--   SELECT DISTINCT role FROM users;               -- 应只有 super_admin/admin/developer/user
--   SELECT DISTINCT stage FROM projects;            -- 应只有 research/.../post_investment
--   \d conversations                                -- 应包含 user_id 列
--   \d projects                                     -- 应包含 priority 列
-- =============================================================================
