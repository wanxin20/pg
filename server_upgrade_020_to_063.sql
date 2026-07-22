-- ════════════════════════════════════════════════════════════════════════════
-- server_upgrade_020_to_063.sql —— 服务端 020 → 063 原子合并迁移（自动生成，勿手改）
-- ════════════════════════════════════════════════════════════════════════════
-- 生成器：scripts/build_server_upgrade_020_to_063.py
-- 适用对象：已经完整执行 001–020、尚未执行 021+ 的 PostgreSQL 数据库。
--
-- 设计：
--   1. 明确纳入全部重复编号文件，排除 datalayer_consolidated/delta 等二次产物；
--   2. 46 个有效源迁移统一放进一个事务，任一步失败都会整体回滚；
--   3. 保留原迁移中的幂等守卫，可在失败回滚后或成功后安全重跑；
--   4. 省略已被 029 当前实现覆盖的 030_token_daily_stats_tz 全表重算；
--   5. 021 会先迁移旧 conversations.messages JSONB，确认落入消息明细后才删旧列。
--
-- 发布铁律：
--   * 先停 server / datacenter worker / 取数飞轮，避免 DDL 与在线写入争锁；
--   * 先做 pg_dump -Fc 备份；
--   * 使用 psql -v ON_ERROR_STOP=1 整体执行，不要逐段选中执行；
--   * 本文件与 021–063 原始脚本二选一，部署记录只记本文件。
--
-- 命令：
--   psql -h HOST -U USER -d DB -v ON_ERROR_STOP=1 -f server_upgrade_020_to_063.sql
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- 在线写入未停时快速失败并原子回滚，避免迁移进程长时间挂起。
SET LOCAL lock_timeout = '10s';

-- 基线预检：允许目标库已经局部执行过 021+，但必须具备 020 的核心表与关键列。
DO $$
DECLARE
    missing_objects TEXT;
BEGIN
    SELECT string_agg(required.object_name, ', ' ORDER BY required.object_name)
    INTO missing_objects
    FROM (
        VALUES
            ('table users', to_regclass('public.users') IS NOT NULL),
            ('table projects', to_regclass('public.projects') IS NOT NULL),
            ('table project_members', to_regclass('public.project_members') IS NOT NULL),
            ('table conversations', to_regclass('public.conversations') IS NOT NULL),
            ('table files', to_regclass('public.files') IS NOT NULL),
            ('table system_config', to_regclass('public.system_config') IS NOT NULL),
            ('table audit_logs', to_regclass('public.audit_logs') IS NOT NULL),
            ('table knowledge_embeddings', to_regclass('public.knowledge_embeddings') IS NOT NULL),
            ('column projects.is_default', EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'projects' AND column_name = 'is_default'
            )),
            ('column conversations.created_at', EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'conversations' AND column_name = 'created_at'
            )),
            ('column files.visibility', EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'files' AND column_name = 'visibility'
            ))
    ) AS required(object_name, present)
    WHERE NOT required.present;

    IF missing_objects IS NOT NULL THEN
        RAISE EXCEPTION '目标数据库不是完整 020 基线，缺少：%', missing_objects;
    END IF;
END
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- [1/46] 会话与项目 · 021_conversation_refactor.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 021: 会话表重构 — 拆分 messages 到独立表 + 聚合字段 + 同步状态 + 审计日志
-- 幂等：可重复执行
-- 兼容：020 及更早版本可能仍在 conversations.messages JSONB 中保存历史消息；
--       本迁移会先把每个 JSON 元素按原顺序复制到 conversation_messages，再删除旧列。

-- ── ① conversations 主表字段扩展 ──────────────────────────────

ALTER TABLE conversations
    -- Agent / 模型绑定
    ADD COLUMN IF NOT EXISTS agent_type            VARCHAR(64),
    ADD COLUMN IF NOT EXISTS model_name            VARCHAR(64),
    -- 生命周期
    ADD COLUMN IF NOT EXISTS status                VARCHAR(16) NOT NULL DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS started_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS last_message_at       TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS ended_at              TIMESTAMPTZ,
    -- 聚合指标：token / 耗时 / 计数
    ADD COLUMN IF NOT EXISTS input_tokens          INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS output_tokens         INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_tokens          INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_duration_ms     INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS first_response_ms     INTEGER,
    ADD COLUMN IF NOT EXISTS tool_calls_count      INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS error_count           INTEGER NOT NULL DEFAULT 0,
    -- 用户评价（会话级）
    ADD COLUMN IF NOT EXISTS rating                INTEGER,
    ADD COLUMN IF NOT EXISTS feedback              TEXT,
    ADD COLUMN IF NOT EXISTS rated_at              TIMESTAMPTZ,
    -- 集团同步状态
    ADD COLUMN IF NOT EXISTS sync_status           VARCHAR(16) NOT NULL DEFAULT 'pending',
    ADD COLUMN IF NOT EXISTS synced_at             TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS sync_retry_count      INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS external_session_id   VARCHAR(128),
    -- 扩展位
    ADD COLUMN IF NOT EXISTS metadata              JSONB;

-- 历史数据：started_at 对齐 created_at（新建表为空表，此语句对新环境无影响）
UPDATE conversations
   SET started_at = created_at
 WHERE started_at > created_at;

-- rating 范围约束：1-5 或 NULL
ALTER TABLE conversations DROP CONSTRAINT IF EXISTS ck_conversations_rating_range;
ALTER TABLE conversations
    ADD CONSTRAINT ck_conversations_rating_range
    CHECK (rating IS NULL OR (rating BETWEEN 1 AND 5));

-- 索引
CREATE INDEX IF NOT EXISTS idx_conv_project_created ON conversations(project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_conv_user_created    ON conversations(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_conv_agent_type      ON conversations(agent_type) WHERE agent_type IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_conv_status          ON conversations(status);
-- 部分索引：只扫需要同步到集团的会话，加速后台 Worker
CREATE INDEX IF NOT EXISTS idx_conv_sync_pending
    ON conversations(ended_at) WHERE sync_status = 'pending';
-- external_session_id 唯一（允许多个 NULL）
CREATE UNIQUE INDEX IF NOT EXISTS uq_conv_external_session_id
    ON conversations(external_session_id) WHERE external_session_id IS NOT NULL;


-- ── ② conversation_messages 消息明细表 ───────────────────────

CREATE TABLE IF NOT EXISTS conversation_messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sequence        INTEGER NOT NULL,                                    -- 会话内序号，0 起
    role            VARCHAR(16) NOT NULL,                                -- user / assistant / system / tool
    content         TEXT,                                                -- 纯文本内容
    content_blocks  JSONB,                                               -- 工具调用 / 多模态原始结构
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    duration_ms     INTEGER,
    vote            INTEGER,                                             -- 1=赞 / -1=踩 / NULL=未评
    vote_comment    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_msg_conv_seq UNIQUE (conversation_id, sequence),
    CONSTRAINT ck_msg_vote CHECK (vote IS NULL OR vote IN (-1, 1))
);

CREATE INDEX IF NOT EXISTS idx_msg_conv_created
    ON conversation_messages(conversation_id, created_at);


-- ── ③ 迁移旧 JSONB 消息并删除旧列 ─────────────────────────────

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'conversations'
          AND column_name = 'messages'
    ) THEN
        -- 旧字段正常形态是 JSON 数组；若遇到历史脏数据（单个对象/字符串），也包成单元素数组保存，
        -- 避免为了适配新结构而静默丢失任何原始内容。完整旧对象会放进 content_blocks 作为兜底证据。
        INSERT INTO conversation_messages (
            conversation_id,
            sequence,
            role,
            content,
            content_blocks,
            created_at
        )
        SELECT
            conversation.id,
            (legacy.ordinality - 1)::INTEGER,
            CASE
                WHEN jsonb_typeof(legacy.message) = 'object'
                    THEN LEFT(COALESCE(NULLIF(legacy.message ->> 'role', ''), 'user'), 16)
                ELSE 'user'
            END,
            CASE
                WHEN jsonb_typeof(legacy.message) = 'string'
                    THEN legacy.message #>> '{}'
                WHEN jsonb_typeof(legacy.message) = 'object'
                     AND jsonb_typeof(legacy.message -> 'content') = 'string'
                    THEN legacy.message ->> 'content'
                ELSE NULL
            END,
            CASE
                WHEN jsonb_typeof(legacy.message) = 'object'
                     AND jsonb_typeof(legacy.message -> 'content_blocks') = 'array'
                    THEN (legacy.message -> 'content_blocks') ||
                         CASE
                             WHEN legacy.extra <> '{}'::jsonb
                                 THEN jsonb_build_array(jsonb_build_object(
                                     'type', 'legacy_metadata', 'data', legacy.extra
                                 ))
                             ELSE '[]'::jsonb
                         END
                WHEN jsonb_typeof(legacy.message) = 'object'
                     AND jsonb_typeof(legacy.message -> 'content') = 'array'
                    THEN (legacy.message -> 'content') ||
                         CASE
                             WHEN legacy.extra <> '{}'::jsonb
                                 THEN jsonb_build_array(jsonb_build_object(
                                     'type', 'legacy_metadata', 'data', legacy.extra
                                 ))
                             ELSE '[]'::jsonb
                         END
                WHEN jsonb_typeof(legacy.message) = 'object' AND legacy.extra <> '{}'::jsonb
                    THEN jsonb_build_array(jsonb_build_object(
                        'type', 'legacy_metadata', 'data', legacy.extra
                    ))
                WHEN jsonb_typeof(legacy.message) = 'array'
                    THEN jsonb_build_array(jsonb_build_object(
                        'type', 'legacy_raw', 'data', legacy.message
                    ))
                ELSE NULL
            END,
            conversation.created_at + ((legacy.ordinality - 1) * INTERVAL '1 microsecond')
        FROM conversations AS conversation
        CROSS JOIN LATERAL jsonb_array_elements(
            CASE
                WHEN jsonb_typeof(conversation.messages) = 'array' THEN conversation.messages
                ELSE jsonb_build_array(conversation.messages)
            END
        ) WITH ORDINALITY AS item(message, ordinality)
        CROSS JOIN LATERAL (
            SELECT
                item.message,
                item.ordinality,
                CASE
                    WHEN jsonb_typeof(item.message) = 'object'
                        THEN item.message - 'role' - 'content' - 'content_blocks'
                    ELSE '{}'::jsonb
                END AS extra
        ) AS legacy
        WHERE conversation.messages IS NOT NULL
          AND conversation.messages <> 'null'::jsonb
        ON CONFLICT (conversation_id, sequence) DO NOTHING;

        ALTER TABLE conversations DROP COLUMN messages;
    END IF;
END
$$;


-- ── ④ conversation_sync_logs 同步审计表 ──────────────────────

CREATE TABLE IF NOT EXISTS conversation_sync_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    attempt         INTEGER NOT NULL,                                    -- 第几次尝试（1 起）
    status          VARCHAR(16) NOT NULL,                                -- success / failed / skipped
    http_status     INTEGER,
    request_payload JSONB,                                               -- 脱敏后的 payload（禁止包含 content）
    response_body   TEXT,
    error_message   TEXT,
    duration_ms     INTEGER,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sync_log_conv_created
    ON conversation_sync_logs(conversation_id, created_at DESC);


-- ── 验证 ──────────────────────────────────────────────────
-- 新列均存在：
-- SELECT COUNT(*) FROM information_schema.columns
--   WHERE table_name = 'conversations'
--     AND column_name IN ('status','sync_status','total_tokens','rating','external_session_id','started_at','ended_at');
-- -- 期望 7
--
-- messages 列已删除：
-- SELECT COUNT(*) FROM information_schema.columns
--   WHERE table_name = 'conversations' AND column_name = 'messages';
-- -- 期望 0
--
-- 新表存在：
-- SELECT table_name FROM information_schema.tables
--   WHERE table_name IN ('conversation_messages','conversation_sync_logs') ORDER BY table_name;
-- -- 期望 2 行
--
-- check 约束生效（预期失败）：
-- INSERT INTO conversation_messages (conversation_id, sequence, role, vote)
--   VALUES (gen_random_uuid(), 0, 'user', 2);

-- ══════════════════════════════════════════════════════════════════════════════
-- [2/46] 会话与项目 · 022_project_categories_and_stages.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 022: 项目类别(category) + 6 阶段重构
--
-- 背景:
--   原 4 阶段(pre_investment / in_investment / post_investment / closed)合并语义不清,
--   产品要求拆为 category(投研/项目池) + stage(投研 / 初筛 / 立项 / 尽调 / 交割 / 投后)。
--
-- 数据迁移规则(由乙方与甲方在 2026-04-27 评审确认):
--   pre_investment   → category='pipeline', stage='screening'        (落入项目池初筛)
--   in_investment    → category='pipeline', stage='closing'          (默认放在交割阶段)
--   post_investment  → category='pipeline', stage='post_investment'  (语义保留)
--   closed           → category='pipeline', stage='post_investment'  (closed 不再保留为 stage,
--                                                                     未来"关闭/归档"由独立 status 字段表达)
--   其他历史脏数据    → category='pipeline', stage='screening'        (兜底)
--   is_default=TRUE  → category='research', stage='research'         (个人空间归到投研)
--
-- 注意:
--   - 列默认值改为 ('research'/'research'),保证新建项目落在投研类别
--   - DB 层不加 CHECK 约束,沿用 app 层 enum 校验(与现有项目惯例一致)
--   - 幂等:多次执行不破坏已迁移数据 — 所有 UPDATE 通过"stage 仍为旧值"作为门槛
--     重复执行时,旧值已不存在,UPDATE 命中 0 行,不会回退手动调整过的项目


-- ── ① 加 category 列(默认 research,与新建语义对齐) ──────────
ALTER TABLE projects
    ADD COLUMN IF NOT EXISTS category VARCHAR(16) NOT NULL DEFAULT 'research';

-- ── ② 数据回填 — 旧 stage → 新 category + 新 stage(单次扫描,CASE 表达式映射) ──
-- WHERE 限定为已知旧值或非新值,保证幂等:已迁移项目不会被二次改写
UPDATE projects
   SET category = 'pipeline',
       stage = CASE stage
           WHEN 'pre_investment'  THEN 'screening'
           WHEN 'in_investment'   THEN 'closing'
           WHEN 'post_investment' THEN 'post_investment'
           WHEN 'closed'          THEN 'post_investment'
           ELSE 'screening'  -- 兜底:未知旧值统一进项目池初筛
       END
 WHERE stage NOT IN (
       'research', 'screening', 'kickoff',
       'due_diligence', 'closing', 'post_investment'
   );

-- ── ③ 个人空间归到投研类别 — 仅在仍为旧 pre_investment(本次未被 ② 覆盖前的状态)时执行 ──
-- ② 已把所有非新 stage 改写完毕,此处仅修正 ② 把 is_default 项目误归到 pipeline 的少量情况;
-- 通过 stage='screening' AND is_default=TRUE 限定:管理员若手动把个人空间设为别的项目池阶段
-- 不会被回退;首次执行时所有 is_default 项目都从 pre_investment→screening,会被命中并修正
UPDATE projects
   SET category = 'research', stage = 'research'
 WHERE is_default = TRUE
   AND category = 'pipeline'
   AND stage = 'screening';

-- ── ④ 修改默认值 — 新项目落在投研 ────────────────────────────
ALTER TABLE projects ALTER COLUMN stage    SET DEFAULT 'research';
ALTER TABLE projects ALTER COLUMN category SET DEFAULT 'research';

-- ── ⑤ 验证(注释,迁移脚本不阻塞) ──────────────────────────────
-- SELECT category, stage, count(*) FROM projects GROUP BY category, stage ORDER BY category, stage;

-- ══════════════════════════════════════════════════════════════════════════════
-- [3/46] 客户端发布 · 023_agent_release.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 023: agent_release — 客户端自动更新版本/包元数据
--
-- 用途:
--   - 给 GET /api/agent/release/manifest 提供"app 层 + runtime 层"最新版数据
--   - 上传/下线/标强制下限 全部走该表
--
-- 物理 zip 文件存于 <RELEASE_STORAGE_PATH>/<layer>/<version>.zip
-- DB 仅存元数据 + 物理路径,文件落盘由 service 层处理。
--
-- 幂等:DDL 全部 IF NOT EXISTS;无数据回填。


CREATE TABLE IF NOT EXISTS agent_release (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    layer       VARCHAR(16) NOT NULL,                -- 'app' | 'runtime'
    version     VARCHAR(32) NOT NULL,                -- semver, 如 '1.2.3'
    sha256      VARCHAR(64) NOT NULL,                -- 包 SHA256(hex,小写)
    size_bytes  BIGINT NOT NULL,
    file_path   VARCHAR(512) NOT NULL,               -- 相对 RELEASE_STORAGE_PATH 的路径
    release_notes TEXT,                              -- 发布说明(中文)
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,       -- false 视同已下线
    is_min_required BOOLEAN NOT NULL DEFAULT FALSE,  -- 强制下限标记
    requires_full_reinstall BOOLEAN NOT NULL DEFAULT FALSE,  -- runtime 层必为 true
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_release_layer_version
    ON agent_release (layer, version);

-- 取最新版常用查询:WHERE layer=? AND is_active ORDER BY created_at DESC LIMIT 1
CREATE INDEX IF NOT EXISTS ix_agent_release_layer_active_created
    ON agent_release (layer, is_active, created_at DESC);


-- 验证:
--   SELECT * FROM agent_release;

-- ══════════════════════════════════════════════════════════════════════════════
-- [4/46] 客户端发布 · 024_release_max_size_config.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 024: 客户端版本上传文件大小上限（动态配置,system_config.value JSONB）
--
-- 用途:agent_release 上传 zip 时,从 system_config 读 'release_max_size_mb' key,
-- 超出即返 413 FILE_TOO_LARGE。
--
-- 默认 2048 MB(2 GB),给 runtime 包未来扩张和打包资源临时膨胀留余量。
-- 幂等:ON CONFLICT (key) DO NOTHING。


INSERT INTO system_config (id, key, value, description, category)
VALUES (
    gen_random_uuid(),
    'release_max_size_mb',
    '{"max_size_mb": 2048}'::jsonb,
    '客户端版本（agent_release）上传 zip 文件的最大大小（MB），默认 2048（2 GB）',
    'general'
)
ON CONFLICT (key) DO NOTHING;


-- 验证:
--   SELECT key, value FROM system_config WHERE key = 'release_max_size_mb';

-- ══════════════════════════════════════════════════════════════════════════════
-- [5/46] 会话统计 · 025_token_stats_index.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 025_token_stats_index.sql
-- 用途：加速「基于用户的 Token 统计」的按用户聚合 + 时间范围过滤。
-- conversations 已是统计唯一数据源，本迁移只加索引，不改表结构。

CREATE INDEX IF NOT EXISTS idx_conversations_user_started
  ON conversations (user_id, started_at);

-- 验证：
-- \d+ conversations  -- 应能看到 idx_conversations_user_started
-- EXPLAIN SELECT user_id, SUM(total_tokens) FROM conversations
--   WHERE user_id IS NOT NULL GROUP BY user_id;  -- 应走索引

-- ══════════════════════════════════════════════════════════════════════════════
-- [6/46] 服务端凭据 · 025_vendor_credentials.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 025: 数据源 vault — vendor 密钥服务端集中加密存储 + proxy 调用审计
--
-- 设计目标:
--   1. 12 个数据源 skill 的 vendor key 100% 留在 server,客户端零持有
--   2. AES-256-GCM 加密(encrypted_value 是 nonce + ciphertext + tag 的 bytes)
--   3. 按 (vendor_slug, env_name) 唯一,支持单 vendor 多 key(如 cloudmap 3 个 / oxvalueai 2 个)
--   4. 审计 vendor proxy 调用(用户 / 接口 / 耗时 / 状态码),用于配额、追责、可观测
--
-- vendor_slug 与 routers/vendor_proxy/ 子模块名一一对应(jingzhun / hibor / cloudmap / mofoun / djyanbao / oxvalueai / bocha / em_saas)
--
-- 幂等:所有 DDL 用 IF NOT EXISTS。
-- 验证 SQL 在文件末尾。


-- ── vendor_credentials:Vault 主表 ─────────────────────────────

CREATE TABLE IF NOT EXISTS vendor_credentials (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_slug     VARCHAR(64)  NOT NULL,
    env_name        VARCHAR(128) NOT NULL,
    encrypted_value BYTEA        NOT NULL,
    description     VARCHAR(256),
    status          VARCHAR(32)  NOT NULL DEFAULT 'active',  -- active | disabled
    rotation_at     TIMESTAMPTZ,                              -- 上次轮换时间
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT vendor_credentials_unique UNIQUE (vendor_slug, env_name)
);

CREATE INDEX IF NOT EXISTS idx_vendor_credentials_vendor_slug
    ON vendor_credentials (vendor_slug);

CREATE INDEX IF NOT EXISTS idx_vendor_credentials_status
    ON vendor_credentials (status);

COMMENT ON TABLE vendor_credentials IS 'Phase B vendor 密钥 vault — encrypted_value 走 AES-256-GCM,master key 在 server VAULT_MASTER_KEY env';
COMMENT ON COLUMN vendor_credentials.encrypted_value IS '布局:nonce(12B) || ciphertext || gcm_tag(16B)';
COMMENT ON COLUMN vendor_credentials.vendor_slug IS '与 apps/server/services/vendor_proxy/ 子模块名一致(jingzhun/hibor/cloudmap/mofoun/djyanbao/oxvalueai/bocha/em_saas)';


-- ── vendor_proxy_audit_log:每次 vendor 代理调用审计 ─────────────

CREATE TABLE IF NOT EXISTS vendor_proxy_audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID         REFERENCES users(id) ON DELETE SET NULL,
    vendor_slug     VARCHAR(64)  NOT NULL,
    operation       VARCHAR(64)  NOT NULL,                  -- 调用路径,如 'search' / 'fetch'
    request_size    INTEGER,                                 -- 请求 body bytes(粗估)
    response_size   INTEGER,                                 -- 响应 bytes(粗估)
    status_code     INTEGER,                                 -- HTTP 状态码
    duration_ms     INTEGER,                                 -- 总耗时(含 vendor 端 + 网络)
    error           TEXT,                                    -- 失败原因(成功时 NULL)
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_vendor_proxy_audit_user_id
    ON vendor_proxy_audit_log (user_id);

CREATE INDEX IF NOT EXISTS idx_vendor_proxy_audit_vendor_slug
    ON vendor_proxy_audit_log (vendor_slug);

CREATE INDEX IF NOT EXISTS idx_vendor_proxy_audit_created_at
    ON vendor_proxy_audit_log (created_at DESC);

COMMENT ON TABLE vendor_proxy_audit_log IS '每条 vendor proxy 调用一行,用户 / 接口 / 状态 / 耗时,供配额限流与可观测';


-- 验证:
-- SELECT vendor_slug, env_name, status, rotation_at FROM vendor_credentials ORDER BY vendor_slug, env_name;
-- SELECT vendor_slug, COUNT(*) FROM vendor_proxy_audit_log GROUP BY vendor_slug;

-- ══════════════════════════════════════════════════════════════════════════════
-- [7/46] 服务端凭据 · 026_vendor_definitions.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 026: vendor_definitions — vendor meta + endpoint 配置中心化
--
-- 设计目标:
--   1. 把硬编码在 services/vendor_proxy/*.py 里的上游 URL 抽到 DB,super_admin 可改
--   2. handler_type 区分"配置驱动"(generic-bearer/header/form)与"代码实现"(custom-<slug>)
--   3. 增加简单 REST vendor 不必改代码:admin 新建 vendor_definitions + 灌 vault key 即可
--   4. config JSONB 字段每种 handler 自定 schema(generic 三种各异,custom 各自一份)
--
-- handler_type 取值:
--   generic-bearer  → 透传 body,header Authorization: Bearer <key>
--                      config: {api_base, endpoints:[{path, name}], key_env_name, [extra_headers]}
--   generic-header  → 透传 body,自定义 header (如 em_api_key)
--                      config: {api_base, endpoints:[{path, name}], header_name, key_env_name}
--   generic-form    → 透传参数为 form-urlencoded,token 放 body 字段
--                      config: {url, token_param, key_env_name, [defaults:{...}]}
--   custom-cloudmap → cloudmap.py(JWT app-access-token 交换 + 3 key)
--                      config: {auth_url, rag_base, [chat_path], [search_path]}
--   custom-djyanbao → djyanbao.py(HMAC-SHA256 递归签名)
--                      config: {api_url}
--   custom-oxvalueai → oxvalueai.py(AES-256-ECB + HMAC)
--                      config: {base_url_test, base_url_prod}
--   custom-jingzhun → jingzhun.py(MCP-over-SSE)
--                      config: {sse_url}


CREATE TABLE IF NOT EXISTS vendor_definitions (
    vendor_slug    VARCHAR(64)  PRIMARY KEY,
    display_name   VARCHAR(128) NOT NULL,
    description    VARCHAR(512),
    handler_type   VARCHAR(64)  NOT NULL,
    config         JSONB        NOT NULL DEFAULT '{}'::jsonb,
    sort_order     INTEGER      NOT NULL DEFAULT 0,
    status         VARCHAR(32)  NOT NULL DEFAULT 'active',
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE vendor_definitions IS 'vendor 元数据 + endpoint 配置,super_admin 可在 admin 后台维护';
COMMENT ON COLUMN vendor_definitions.handler_type IS 'generic-* 走配置驱动 handler,custom-* 走代码 handler;详见 services/vendor_proxy/__init__.py';
COMMENT ON COLUMN vendor_definitions.config IS 'handler 私有 schema,JSONB 由 admin UI 渲染对应表单';

CREATE INDEX IF NOT EXISTS idx_vendor_definitions_handler_type ON vendor_definitions (handler_type);
CREATE INDEX IF NOT EXISTS idx_vendor_definitions_status ON vendor_definitions (status);

-- ── 灌入 8 个现有 vendor 的初始数据 ─────────────────────────

INSERT INTO vendor_definitions (vendor_slug, display_name, description, handler_type, config, sort_order) VALUES
    -- 简单 REST vendor → generic handler
    ('bocha', '博查 Bocha(联网搜索)', '全网搜索 + AI 搜索,Bearer 鉴权', 'generic-bearer',
        '{
            "api_base": "https://api.bocha.cn",
            "endpoints": [
                {"path": "/v1/web-search", "name": "web-search"},
                {"path": "/v1/ai-search", "name": "ai-search"}
            ],
            "key_env_name": "BOCHA_API_KEY",
            "extra_headers": {"User-Agent": "haier-search-fund/web-search-skill"}
        }'::jsonb, 70),

    ('em_saas', '东方财富妙想(5 mx_* skill 共用)', '二级市场 + 宏观 + 资讯 + 选股 + 问答',
        'generic-header',
        '{
            "api_base": "https://ai-saas.eastmoney.com",
            "endpoints": [
                {"path": "/proxy/b/mcp/tool/searchData", "name": "search-data"},
                {"path": "/proxy/b/mcp/tool/searchMacroData", "name": "search-macro-data"},
                {"path": "/proxy/b/mcp/tool/selectSecurity", "name": "select-security"},
                {"path": "/proxy/b/mcp/tool/searchNews", "name": "search-news"},
                {"path": "/proxy/app-robo-advisor-api/assistant/ask", "name": "assistant-ask", "inject_tool_context": false}
            ],
            "header_name": "em_api_key",
            "key_env_name": "EM_API_KEY",
            "inject_tool_context": true
        }'::jsonb, 80),

    ('hibor', '慧博(研报)', '慧博 OpenAPI 研报清单 / 全文 / 探活', 'generic-form',
        '{
            "url": "https://opentest.hibor.com.cn/OpenAPI/YanBao/List",
            "endpoints": [
                {"path": "", "name": "list"}
            ],
            "token_param": "token",
            "key_env_name": "HIBOR_TOKEN"
        }'::jsonb, 20),

    ('mofoun', '发现报告(研报)', 'mofoun.com SAAS,JSON Authorization', 'generic-bearer',
        '{
            "api_base": "https://biz-test.mofoun.com",
            "endpoints": [
                {"path": "/mofoun/saas/search", "name": "search"},
                {"path": "/mofoun/saas/details", "name": "details"}
            ],
            "key_env_name": "MOFOUN_TOKEN",
            "auth_header_value_format": "{key}"
        }'::jsonb, 30),

    -- 复杂签名 / 协议 vendor → custom handler
    ('cloudmap', '海尔云图(行研知识)', '海尔内部 RAG,kcode/ksecret 换 JWT app-access-token',
        'custom-cloudmap',
        '{
            "auth_url": "https://techless-test.haier.net/api/appauth/create/token",
            "rag_base": "https://rag-test.haier.net"
        }'::jsonb, 90),

    ('djyanbao', '洞见研报', 'accessKey + HMAC-SHA256 递归签名', 'custom-djyanbao',
        '{"api_url": "https://openapi.djyanbao.com/api"}'::jsonb, 40),

    ('oxvalueai', '牛津估值', 'AES-256-ECB + HMAC 签名,test/prod 双环境', 'custom-oxvalueai',
        '{
            "base_url_test": "https://test.oxvalue.cn/api/v1",
            "base_url_prod": "https://www.oxvalue.cn/api/v1"
        }'::jsonb, 50),

    ('jingzhun', '鲸准(一级市场)', 'MCP-over-SSE,4 个 ES tool', 'custom-jingzhun',
        '{"sse_url": "https://mcp.jingdata.com/sse"}'::jsonb, 10)
ON CONFLICT (vendor_slug) DO NOTHING;  -- 只在第一次部署时灌入默认;之后 super_admin 在 admin 后台改的配置不被覆盖


-- 验证:
--   SELECT vendor_slug, handler_type, config->>'api_base' AS base FROM vendor_definitions ORDER BY sort_order;

-- ══════════════════════════════════════════════════════════════════════════════
-- [8/46] 服务端凭据 · 027_oxvalueai_default_env.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 027: oxvalueai 环境(env)收口到服务端 vendor_definitions.config
--
-- 背景:
--   此前 test/prod 环境由客户端(skill ox_client.py)在每次请求 body 里传 env,
--   服务端 oxvalueai handler 据此选 base_url。这让客户端能自行决定打 prod/test,
--   不符合"环境属服务端职责"的原则(服务端才持有凭证与 base_url)。
--
-- 本迁移:
--   给 oxvalueai 的 config 补一个权威的 env 字段。服务端 handler 改为只读 config.env,
--   丢弃客户端传入的 env。缺省取 test(更安全,避免误打生产)。
--
-- 注意:
--   迁移 026 用 ON CONFLICT DO NOTHING 灌初始数据,已存在的 oxvalueai 行不含 env,
--   故这里用 UPDATE 幂等补齐(仅当 config 尚无 env 键时写入,不覆盖 admin 已设的值)。
--   上生产时由 super_admin 在 admin 后台「数据源」把 env 改为 "prod"
--   (PUT /api/admin/vendor-definitions/oxvalueai)。


UPDATE vendor_definitions
SET config = jsonb_set(config, '{env}', '"test"', true),
    updated_at = now()
WHERE vendor_slug = 'oxvalueai'
  AND NOT (config ? 'env');


-- 验证:
--   SELECT vendor_slug, config->>'env' AS env, config->>'base_url_test' AS test_url
--   FROM vendor_definitions WHERE vendor_slug = 'oxvalueai';
--   -- 期望 env = 'test'

-- ══════════════════════════════════════════════════════════════════════════════
-- [9/46] 数据层基础 · 027_data_layer_v3_kickoff.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 迁移脚本 027: 数据层 v3.0 飞轮启动 — Phase D-1
-- 依赖: 026_vendor_definitions.sql
-- 文档: docs/data-layer/数据层方案.md §3.0
-- =============================================================================
-- 本迁移为"数据飞轮"打基础:
--   1. files 表加 3 个元数据字段(provenance / trust_tier / freshness_until),
--      让任何文件都能标注"从哪来 / 信任度多高 / 何时过期"
--   2. 新建 vendor_call_log 表:每次 vendor proxy 调用一行,留 request_hash + 沉淀状态,
--      给 "先查 KB → miss 才调外部" 飞轮闭环 + 命中率监控用
--   3. seed 一个 system user + __VENDOR_KB__ project(项目制,无 workspace),
--      承载所有 vendor 自动沉淀的文件(挂在 project_id NOT NULL 的约束下)
--
-- 本迁移不动 knowledge_embeddings — vendor 数据走 files → KnowledgeService.index_file
-- 标准路径入向量库,复用全部现成基础设施。
-- =============================================================================


-- ── 1. files 表元数据扩展 ────────────────────────────────────────

-- provenance: 数据来源链。
--   vendor 沉淀 → {"source":"vendor","vendor":"hibor","operation":"list","req_hash":"...",
--                  "called_at":"...","called_by_user_id":"..."}
--   用户上传   → {"source":"user_upload","uploaded_at":"...","client_ip":"..."}
--   Agent 产物 → {"source":"agent_output","conversation_id":"...","skill":"..."}
ALTER TABLE files
    ADD COLUMN IF NOT EXISTS provenance JSONB NULL;

-- trust_tier: 信任度,影响检索权重 + ACL。
--   ⚠ 本迁移建表时为旧 5 档(internal / external_paid / external_free / user_upload / agent_output);
--     数据层 M2-S2 已升级为 6 档,旧值由 migration 038 重写、CHECK 放开。当前终态档位(enums.py
--     TrustTier)为:
--       internal_official  (海尔内部权威:cloudmap / 投决纪要)— 最高权重
--       external_verified  (付费/官方外部:鲸准 / 牛津 / 三源研报)
--       verified           (人工核验过的外部源)
--       user_upload        (用户上传)
--       web_low            (免费 web 检索:博查 web-search)— 低信任
--       agent_generated    (Agent 自动产物)— 默认低权重
--     下方 CHECK 仍写旧 5 档是历史快照;真正生效的约束以 038 重建后的 chk_files_trust_tier 为准。
-- enum 留作 app 层强约束,DB 层用 VARCHAR + CHECK 保持灵活
ALTER TABLE files
    ADD COLUMN IF NOT EXISTS trust_tier VARCHAR(32) NULL;

ALTER TABLE files
    DROP CONSTRAINT IF EXISTS chk_files_trust_tier;
ALTER TABLE files
    ADD CONSTRAINT chk_files_trust_tier CHECK (
        trust_tier IS NULL OR trust_tier IN (
            'internal', 'external_paid', 'external_free', 'user_upload', 'agent_output'
        )
    );

-- freshness_until: 过期截止时间。
--   NULL  = 永久(用户上传 / 投决纪要 / Agent 产物)
--   有值  = 该时刻起视为过期,飞轮缓存查询会跳过过期 chunks 回退外部 API
--   建议:研报 12 个月,公司估值 6 个月,二级市场行情类不沉淀(不写本表),
--        新闻类 3 个月
ALTER TABLE files
    ADD COLUMN IF NOT EXISTS freshness_until TIMESTAMPTZ NULL;

CREATE INDEX IF NOT EXISTS idx_files_trust_tier ON files(trust_tier);
CREATE INDEX IF NOT EXISTS idx_files_freshness_until ON files(freshness_until);
-- provenance->>'vendor' 高频查询(飞轮命中按 vendor 过滤),建表达式索引
CREATE INDEX IF NOT EXISTS idx_files_provenance_vendor
    ON files((provenance->>'vendor'))
    WHERE provenance IS NOT NULL;


-- ── 2. vendor_call_log 表 ───────────────────────────────────────

-- 每次 vendor proxy 调用一行。和 audit 表(模型层 audit.py)区别:
--   audit  关注"谁调了什么"(权限 / 安全 / 用量审计)
--   本表   关注"飞轮转得怎样"(沉淀状态 / 命中率 / 去重)
-- 两者并存:audit 永久不删 + 全量;本表可按周清理且只记沉淀候选调用。
CREATE TABLE IF NOT EXISTS vendor_call_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_slug     VARCHAR(64)  NOT NULL,
    operation       VARCHAR(128) NOT NULL,
    -- sha256(canonical_json(body)) — 用于飞轮命中判断 + 去重
    request_hash    CHAR(64)     NOT NULL,
    user_id         UUID         NULL REFERENCES users(id) ON DELETE SET NULL,
    -- 本次调用是否命中 KB cache(true 则未实际调外部 API)
    hit_cache       BOOLEAN      NOT NULL DEFAULT FALSE,
    -- 命中时记录所用 cache 的"年龄"(秒)— 诊断 freshness 策略是否合理
    cache_age_seconds INTEGER    NULL,
    -- 沉淀产生的 file_id(每次调用最多一个 file,内含 1~N 个 chunk)
    ingested_file_id UUID        NULL REFERENCES files(id) ON DELETE SET NULL,
    -- pending  → 异步 task 排队中
    -- skipped  → 该 vendor/op 配置为不沉淀(透传)
    -- completed→ file 已建 + chunks 已 embed
    -- failed   → 沉淀失败(error 字段含原因)
    ingest_status   VARCHAR(16)  NOT NULL DEFAULT 'pending',
    ingest_error    TEXT         NULL,
    duration_ms     INTEGER      NULL,
    called_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 飞轮命中查询:WHERE vendor_slug=? AND operation=? AND request_hash=? ORDER BY called_at DESC
CREATE INDEX IF NOT EXISTS idx_vendor_call_log_lookup
    ON vendor_call_log(vendor_slug, operation, request_hash, called_at DESC);

-- 管理面板"命中率"查询
CREATE INDEX IF NOT EXISTS idx_vendor_call_log_recent
    ON vendor_call_log(vendor_slug, called_at DESC);

-- ingest 失败重试 / 巡检
CREATE INDEX IF NOT EXISTS idx_vendor_call_log_failed
    ON vendor_call_log(ingest_status, called_at DESC)
    WHERE ingest_status IN ('pending', 'failed');


-- ── 3. system user + __VENDOR_KB__ project seed(项目制:无 workspace)──

-- 固定 UUID,sinker 代码直接引用(避免每次启动查表)。
-- 写死 UUID 是工程取舍:运行时少一次查询 + 跨环境一致。
-- 修改这些 UUID 必须同步改 services/vendor_proxy/sinkers/base.py 的常量。

-- 3.1 system user — vendor 沉淀文件的 owner_id
INSERT INTO users (id, username, email, password_hash, display_name, role, status)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    '__system__',
    'system@haier-search-fund.internal',
    '',  -- 空 hash,登录路径会拒绝(role='system' 也不进 RBAC)
    '系统账号(vendor 沉淀)',
    'system',
    'active'
)
ON CONFLICT (id) DO NOTHING;

-- 3.2 __VENDOR_KB__ project — 所有 vendor 沉淀文件 project_id = 此 UUID;后续可按 vendor 在 directories 下分子目录
-- ⚠ 平台自 006_remove_workspace_add_project_members 起「移除 workspace,以项目为单位」:
--    projects.workspace_id 列与 workspaces 表均已删。故本 seed 不再建 workspace、projects 不带
--    workspace_id;系统账号(...0001)直接作为 owner。category 省略走默认 'research',stage 无 CHECK。
INSERT INTO projects (id, name, description, owner_id, stage)
VALUES (
    '00000000-0000-0000-0000-000000000003',
    '__VENDOR_KB__',
    'Vendor 自动沉淀知识库 — 所有 sinker 写入的文件归属此 project',
    '00000000-0000-0000-0000-000000000001',
    'active'
)
ON CONFLICT (id) DO NOTHING;


-- ── 4. data_layer 配置(放 system_config)──────────────────────

-- 每个 vendor / operation 的 sinker 策略与 TTL 配置。运行时由
-- VendorSinkerRegistry 读取 → 决定"沉淀 / 透传 / 透传但记 log"。
-- 后续在 admin 也能改这个配置(类似 vendor_definitions 的二级页面)。
INSERT INTO system_config (id, key, value, description, category)
VALUES (
    gen_random_uuid(),
    'data_layer',
    '{
        "sinkers": {
            "hibor:list":       {"action": "ingest", "trust_tier": "external_paid", "ttl_days": 365},
            "mofoun:search":    {"action": "ingest", "trust_tier": "external_paid", "ttl_days": 365},
            "mofoun:details":   {"action": "ingest", "trust_tier": "external_paid", "ttl_days": 365},
            "djyanbao:*":       {"action": "ingest", "trust_tier": "external_paid", "ttl_days": 365},
            "oxvalueai:*":      {"action": "ingest", "trust_tier": "external_paid", "ttl_days": 180},
            "bocha:*":          {"action": "ingest", "trust_tier": "external_free", "ttl_days": 90},
            "jingzhundata:*":   {"action": "ingest", "trust_tier": "external_paid", "ttl_days": 180},
            "em_saas:*":        {"action": "passthrough", "reason": "二级市场 / 行情类时效短不沉淀"},
            "cloudmap:*":       {"action": "passthrough", "reason": "本身就是内部 RAG,不再二次沉淀"}
        },
        "default_action": "passthrough",
        "system_user_id":      "00000000-0000-0000-0000-000000000001",
        "vendor_kb_project_id":"00000000-0000-0000-0000-000000000003"
    }'::jsonb,
    '数据层 v3.0 飞轮配置:每个 vendor/op 的沉淀策略 + TTL + system seed UUID',
    'general'
)
-- 只在首次部署时写默认值；重跑迁移不得覆盖管理后台已经调整过的 sinker/TTL 配置。
-- 后续迁移 038/041/042/043 会用带 WHERE 守卫的增量方式修正历史键名与信任档。
ON CONFLICT (key) DO NOTHING;


-- =============================================================================
-- 验证 SQL:
--   \d+ files                        -- 应含 provenance / trust_tier / freshness_until
--   \d  vendor_call_log              -- 新表
--   SELECT * FROM users     WHERE id = '00000000-0000-0000-0000-000000000001';
--   SELECT * FROM projects  WHERE id = '00000000-0000-0000-0000-000000000003';
--   SELECT key, value FROM system_config WHERE key = 'data_layer';
-- =============================================================================

-- ══════════════════════════════════════════════════════════════════════════════
-- [10/46] 系统配置 · 028_skill_packaging_config.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 028_skill_packaging_config.sql
-- 为 system_config 写入「技能大目录打包」配置项 skill_packaging。
-- 上传技能时，命中 archive_dir_prefixes 且文件数 >= min_files_to_archive 的目录
-- 会被整体打包成 zip 存入 FileStorage，DB 仅记一条 storage_key 指针行。
-- 幂等：ON CONFLICT (key) DO NOTHING，避免重跑时覆盖管理后台保存的自定义打包策略。

INSERT INTO system_config (id, key, value, description, category)
VALUES (
    gen_random_uuid(),
    'skill_packaging',
    '{"archive_dir_prefixes":["templates/icons","templates/decks","templates/layouts","templates/charts","templates/brands"],"min_files_to_archive":10}'::jsonb,
    '技能上传时按目录前缀整体打包入文件存储的配置（archive_dir_prefixes / min_files_to_archive）',
    'general'
)
ON CONFLICT (key) DO NOTHING;

-- 验证：
-- SELECT key, value FROM system_config WHERE key = 'skill_packaging';

-- ══════════════════════════════════════════════════════════════════════════════
-- [11/46] 数据层基础 · 029_datacenter_dl_tables.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 029_datacenter_dl_tables.sql
-- 数据中台 · 结构化知识库 —— dl_* 五表（规范实体 / 关系 / 属性 / 事件 / 数据点）。
--
-- 由 apps/datacenter 处理流水线（构图 → 三层对齐 → 事件/数据点抽取 → 入库）写入，
-- 是"①实体/图谱路径"的落点；与 apps/server 的 knowledge_embeddings（②chunk 文本路径）
-- 通过 chunk_ids 互喂。表结构与 apps/datacenter/pipeline/store 的 SQLite 实验版 1:1，
-- 仅 embedding 列换成 vector(1024) + HNSW，向量检索在库内完成。
--
-- 多租户：每表带 project_id（同 apps/server 各表沿用），检索原语 / 控制台 API 一律按 project_id 隔离。
-- 幂等：全部 IF NOT EXISTS；处理流水线对单个 project 采用"先删后插"全量重建（P3 再做增量）。

CREATE EXTENSION IF NOT EXISTS vector;

-- ── 规范实体（对齐后一行一个现实实体；aliases 收全部表面形 → 查任一别名都命中同一实体）──
CREATE TABLE IF NOT EXISTS dl_entity (
    id          BIGSERIAL   PRIMARY KEY,
    project_id  UUID        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    canonical   TEXT        NOT NULL,
    etype       TEXT        NOT NULL,
    mentions    INT         NOT NULL DEFAULT 0,
    aliases     JSONB       NOT NULL DEFAULT '[]',
    chunk_ids   JSONB       NOT NULL DEFAULT '[]',
    embedding   vector(1024),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (project_id, canonical, etype)
);
-- (project_id) 单列索引省略：下面 (project_id, etype) 复合索引已覆盖按 project 查询 + project FK 级联删除
CREATE INDEX IF NOT EXISTS idx_dl_entity_etype   ON dl_entity (project_id, etype);
CREATE INDEX IF NOT EXISTS idx_dl_entity_emb     ON dl_entity USING hnsw (embedding vector_cosine_ops);

-- ── 实体—实体关系（对齐后按规范名重写三元组、去重带计数；weight = 语料中被抽到的次数）──
CREATE TABLE IF NOT EXISTS dl_relation (
    id          BIGSERIAL PRIMARY KEY,
    project_id  UUID      NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    src_id      BIGINT    NOT NULL REFERENCES dl_entity(id) ON DELETE CASCADE,
    relation    TEXT      NOT NULL,
    dst_id      BIGINT    NOT NULL REFERENCES dl_entity(id) ON DELETE CASCADE,
    weight      INT       NOT NULL DEFAULT 1,
    chunk_ids   JSONB     NOT NULL DEFAULT '[]',
    UNIQUE (project_id, src_id, relation, dst_id)
);
CREATE INDEX IF NOT EXISTS idx_dl_rel_project ON dl_relation (project_id);
CREATE INDEX IF NOT EXISTS idx_dl_rel_src     ON dl_relation (src_id);
CREATE INDEX IF NOT EXISTS idx_dl_rel_dst     ON dl_relation (dst_id);

-- ── 实体属性（youtu has_attribute 边；attr=键，value=值，来自抽取）──
CREATE TABLE IF NOT EXISTS dl_attribute (
    id          BIGSERIAL PRIMARY KEY,
    project_id  UUID      NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    entity_id   BIGINT    NOT NULL REFERENCES dl_entity(id) ON DELETE CASCADE,
    attr        TEXT      NOT NULL,
    value       TEXT,
    chunk_ids   JSONB     NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_dl_attr_project ON dl_attribute (project_id);
CREATE INDEX IF NOT EXISTS idx_dl_attr_entity  ON dl_attribute (entity_id);

-- ── 事件（逐篇抽取 + 事件归一后；source_count = 多少篇研报报道过同一事件）──
CREATE TABLE IF NOT EXISTS dl_event (
    id            BIGSERIAL PRIMARY KEY,
    project_id    UUID      NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    etype         TEXT      NOT NULL,
    event_date    TEXT      NOT NULL DEFAULT '',   -- '' = 无日期；YYYY / YYYY-MM / YYYY-MM-DD
    title         TEXT      NOT NULL,
    participants  JSONB     NOT NULL DEFAULT '[]',
    value         TEXT,
    source_doc    TEXT,
    source_count  INT       NOT NULL DEFAULT 1,
    UNIQUE (project_id, etype, event_date, title)
);
-- (project_id) 单列索引省略：下面 (project_id, *) 复合索引已覆盖
CREATE INDEX IF NOT EXISTS idx_dl_event_date    ON dl_event (project_id, event_date);
CREATE INDEX IF NOT EXISTS idx_dl_event_type    ON dl_event (project_id, etype);

-- ── 数据点（带值的量化事实，补 youtu 空属性；同实体同指标多值 = 多方口径冲突）──
CREATE TABLE IF NOT EXISTS dl_datapoint (
    id          BIGSERIAL PRIMARY KEY,
    project_id  UUID      NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    entity      TEXT      NOT NULL,
    metric      TEXT      NOT NULL,
    value       TEXT      NOT NULL,
    unit        TEXT,
    dp_date     TEXT,
    source_doc  TEXT,
    UNIQUE (project_id, entity, metric, value, dp_date)
);
-- (project_id) 单列索引省略：下面 (project_id, entity) 复合索引已覆盖
CREATE INDEX IF NOT EXISTS idx_dl_dp_entity  ON dl_datapoint (project_id, entity);

-- ── 验证 SQL（迁移后手动核对）──
-- SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'dl\_%';
--   预期 5 张：dl_entity / dl_relation / dl_attribute / dl_event / dl_datapoint
-- SELECT indexname FROM pg_indexes WHERE indexname = 'idx_dl_entity_emb';   -- HNSW 向量索引存在
-- \d dl_entity    -- 确认 embedding 列类型为 vector(1024)

-- ══════════════════════════════════════════════════════════════════════════════
-- [12/46] 会话统计 · 029_token_daily_stats.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 029_token_daily_stats.sql
-- Token 按天实时统计：消息级补 cache 两列 + 会话×天预聚合表 + 历史回填。
-- 解决「跨天续聊时，今天的 token 因会话 started_at 在前几天而无法按天统计到」。
-- 全部幂等。

-- ── 1. conversation_messages 补 cache 两列（消息级精确 cache token）──
ALTER TABLE conversation_messages
  ADD COLUMN IF NOT EXISTS cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cache_creation_tokens INTEGER NOT NULL DEFAULT 0;

-- ── 2. 会话×天预聚合表 ──
CREATE TABLE IF NOT EXISTS conversation_daily_tokens (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,  -- 冗余，免 join
    agent_type      VARCHAR(64),     -- 冗余自 conversation，供 by-skill 聚合
    model_name      VARCHAR(64),     -- 冗余自 conversation，供 by-model 聚合
    stat_date       DATE NOT NULL,   -- 消息 created_at 的自然日（按会话 TimeZone 解析）
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    total_tokens          INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    total_duration_ms     INTEGER NOT NULL DEFAULT 0,
    message_count         INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_conv_daily UNIQUE (conversation_id, stat_date)
);
CREATE INDEX IF NOT EXISTS idx_conv_daily_user_date ON conversation_daily_tokens (user_id, stat_date);
CREATE INDEX IF NOT EXISTS idx_conv_daily_date ON conversation_daily_tokens (stat_date);

-- ── 3. 历史回填（按现有消息逐天聚合；历史消息 cache 列默认 0，历史 cache 不精确，新数据精确）──
INSERT INTO conversation_daily_tokens
    (conversation_id, user_id, agent_type, model_name, stat_date,
     input_tokens, output_tokens, total_tokens, cache_read_tokens, cache_creation_tokens,
     total_duration_ms, message_count)
SELECT m.conversation_id, c.user_id, c.agent_type, c.model_name, date(m.created_at AT TIME ZONE 'Asia/Shanghai'),
       SUM(m.input_tokens), SUM(m.output_tokens),
       SUM(m.input_tokens + m.output_tokens + m.cache_read_tokens + m.cache_creation_tokens),
       SUM(m.cache_read_tokens), SUM(m.cache_creation_tokens),
       SUM(COALESCE(m.duration_ms, 0)), COUNT(*)
FROM conversation_messages m
JOIN conversations c ON c.id = m.conversation_id
GROUP BY m.conversation_id, c.user_id, c.agent_type, c.model_name, date(m.created_at AT TIME ZONE 'Asia/Shanghai')
ON CONFLICT (conversation_id, stat_date) DO NOTHING;

-- 验证：
-- SELECT count(*) FROM conversation_daily_tokens;
-- SELECT stat_date, sum(total_tokens) FROM conversation_daily_tokens GROUP BY stat_date ORDER BY stat_date DESC LIMIT 7;

-- ══════════════════════════════════════════════════════════════════════════════
-- [13/46] 数据层基础 · 030_datacenter_build_metrics.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 迁移 030: 数据中台 build 性能/成本埋点
-- 每次 datalayer_build 记一行：分阶段耗时 + LLM/嵌入 token 消耗 + 产物计数。
-- 目的：数据层是优化项目，build 成本（时间/token）要可量化、可汇报、可对比现状流程；
--      集成到生产后同样需要（控制台"构建历史"页 + 成本监控）。
-- 依赖：projects（001）。
-- =============================================================================

CREATE TABLE IF NOT EXISTS dl_build_metrics (
    id                    BIGSERIAL PRIMARY KEY,
    project_id            UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- 产物计数（与 build 返回的 counts 一致）
    docs                  INT NOT NULL DEFAULT 0,
    chunks                INT NOT NULL DEFAULT 0,   -- construct 切出的 chunk 数
    entities              INT NOT NULL DEFAULT 0,
    relations             INT NOT NULL DEFAULT 0,
    attributes            INT NOT NULL DEFAULT 0,
    events                INT NOT NULL DEFAULT 0,
    datapoints            INT NOT NULL DEFAULT 0,
    input_chars           BIGINT NOT NULL DEFAULT 0,  -- 输入语料总字符数（衡量规模）

    -- 分阶段耗时（秒，perf_counter）
    total_seconds         REAL NOT NULL DEFAULT 0,
    construct_seconds     REAL NOT NULL DEFAULT 0,
    align_seconds         REAL NOT NULL DEFAULT 0,
    extract_seconds       REAL NOT NULL DEFAULT 0,
    consolidate_seconds   REAL NOT NULL DEFAULT 0,
    persist_seconds       REAL NOT NULL DEFAULT 0,

    -- LLM（DeepSeek）消耗；实调用才计 token，缓存命中只计 cache_hits（反映真实成本）
    llm_calls             INT    NOT NULL DEFAULT 0,
    llm_cache_hits        INT    NOT NULL DEFAULT 0,
    llm_prompt_tokens     BIGINT NOT NULL DEFAULT 0,
    llm_completion_tokens BIGINT NOT NULL DEFAULT 0,

    -- 嵌入（qwen3-vl）消耗
    emb_calls             INT    NOT NULL DEFAULT 0,
    emb_cache_hits        INT    NOT NULL DEFAULT 0,
    emb_tokens            BIGINT NOT NULL DEFAULT 0,

    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 按项目 + 时间倒序：取某项目最近一次/历次 build 成本
CREATE INDEX IF NOT EXISTS idx_dl_build_metrics_project
    ON dl_build_metrics (project_id, created_at DESC);

-- =============================================================================
-- 验证:
--   SELECT project_id, entities, total_seconds,
--          llm_prompt_tokens + llm_completion_tokens AS llm_tokens, emb_tokens, created_at
--   FROM dl_build_metrics ORDER BY created_at DESC LIMIT 5;
-- =============================================================================

-- ══════════════════════════════════════════════════════════════════════════════
-- [14/46] 数据层 ACL · 031_file_visibility_fund_wide.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 031_file_visibility_fund_wide.sql
-- 数据层 M1-S2 · files.visibility 放开容纳 "fund_wide"（全公司可见档）。
--
-- 背景：FileVisibility 现仅 PERSONAL / PROJECT（enums.py:48-51），共享层 M2 需新增
-- "fund_wide"（KAG「身份层共享 + 证据层 ACL」中的「全公司可见」级别），vendor 沉淀去
-- __VENDOR_KB__ 假项目后改写 visibility='fund_wide'（M2-S3）。
--
-- 关键事实：files.visibility 由 006_remove_workspace_add_project_members.sql:41 定义为
--   VARCHAR(16) NOT NULL DEFAULT 'project'，**当前无 CHECK 约束**（全仓 grep 确认）。
-- 因此本迁移无需放开任何约束——VARCHAR(16) 已能容纳 'fund_wide'（9 字符）。
-- 本脚本做「防御性兜底」：若未来有人补了限制 visibility 取值的 CHECK 约束，则放开它。
--
-- 幂等：DO 块条件性 DROP CHECK（仅当存在且不含 fund_wide 时）；可重放。

-- ── 防御性放开 visibility CHECK 约束（若存在且未容纳 fund_wide）─────────────────
-- 遍历 files 表上所有 CHECK 约束，找出约束定义里提及 visibility 但不含 fund_wide 的，
-- 删除后重建为包含 fund_wide 的版本。当前无此类约束 → DO 块空跑（无副作用）。
DO $$
DECLARE
    con RECORD;
BEGIN
    FOR con IN
        SELECT c.conname, pg_get_constraintdef(c.oid) AS def
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = 'files'
          AND c.contype = 'c'
          AND pg_get_constraintdef(c.oid) ILIKE '%visibility%'
          AND pg_get_constraintdef(c.oid) NOT ILIKE '%fund_wide%'
    LOOP
        -- 删除旧约束（不容纳 fund_wide）
        EXECUTE format('ALTER TABLE files DROP CONSTRAINT %I', con.conname);
        -- 重建为包含 personal/project/fund_wide 三档的白名单 CHECK
        EXECUTE format(
            'ALTER TABLE files ADD CONSTRAINT %I CHECK (visibility IN (''personal'', ''project'', ''fund_wide''))',
            con.conname
        );
        RAISE NOTICE '031: 已放开 files CHECK 约束 % 以容纳 fund_wide', con.conname;
    END LOOP;
END $$;

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 确认 visibility 列宽足以容纳 'fund_wide'（应为 character varying(16)）：
--    SELECT data_type, character_maximum_length FROM information_schema.columns
--      WHERE table_name = 'files' AND column_name = 'visibility';
-- 2) 确认无 CHECK 约束会拒绝 fund_wide（应返回 0 行）：
--    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--      WHERE conrelid = 'files'::regclass AND contype = 'c'
--        AND pg_get_constraintdef(oid) ILIKE '%visibility%'
--        AND pg_get_constraintdef(oid) NOT ILIKE '%fund_wide%';
-- 3) 冒烟：插入/更新一行 visibility='fund_wide' 不报错（业务侧验证 upload 200）。

-- ══════════════════════════════════════════════════════════════════════════════
-- [15/46] 数据层 ACL · 032_dl_acl_provenance_columns.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 032_dl_acl_provenance_columns.sql
-- 数据层 M1-S3 · dl_* 五表统一加 ACL + provenance 列（只建列，过滤哲学归 M2）。
--
-- 给 dl_entity / dl_relation / dl_attribute / dl_event / dl_datapoint 五表各加：
--   visibility      VARCHAR(16)    可见性档（personal / project / fund_wide）——共享层 ACL WHERE 读
--   trust_tier      VARCHAR(32)    信任档（6 档，见 enums.py TrustTier）——检索粗排加权读
--   freshness_until TIMESTAMPTZ    新鲜度截止——过期不当新（freshness 过滤读）
--   source_id       UUID           来源文件 id（逻辑指 files.id）——provenance 溯源 / 可见性 join 推导
--   revoked_at      TIMESTAMPTZ    软撤时间戳——收回=软撤（M2-S5），NULL=未撤
--
-- 借鉴：KAG「每条断言挂 source 指针」——source_id 即 add_edge(..., 'source', chunk.id) 的列化。
--
-- 设计取舍：
--   * source_id 故意**不加硬 FK 约束**到 files——dl_* 由 datacenter 流水线全量重建/增量写，
--     绑硬 FK 会在重建顺序 / 跨库（vendor 沉淀 file 可能晚于 dl_* 行）时引入删除/插入顺序耦合；
--     可见性 join 推导（M4-S5）按 source_id 软 join files 即可。
--   * 这些列**先不填默认值/NOT NULL**——M2-S1/S2 注入过滤时按 NULL 走「保守可见 + 默认档」语义，
--     writer（M1-S3 配套）从抽取产物的 source 绑定回填，避免存量行被强制改写。
--
-- 幂等：全部 ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS；可重放。

-- ── dl_entity ──────────────────────────────────────────────────
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS visibility      VARCHAR(16);
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS trust_tier      VARCHAR(32);
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS freshness_until TIMESTAMPTZ;
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS source_id       UUID;
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS revoked_at      TIMESTAMPTZ;

-- ── dl_relation ────────────────────────────────────────────────
ALTER TABLE dl_relation ADD COLUMN IF NOT EXISTS visibility      VARCHAR(16);
ALTER TABLE dl_relation ADD COLUMN IF NOT EXISTS trust_tier      VARCHAR(32);
ALTER TABLE dl_relation ADD COLUMN IF NOT EXISTS freshness_until TIMESTAMPTZ;
ALTER TABLE dl_relation ADD COLUMN IF NOT EXISTS source_id       UUID;
ALTER TABLE dl_relation ADD COLUMN IF NOT EXISTS revoked_at      TIMESTAMPTZ;

-- ── dl_attribute ───────────────────────────────────────────────
ALTER TABLE dl_attribute ADD COLUMN IF NOT EXISTS visibility      VARCHAR(16);
ALTER TABLE dl_attribute ADD COLUMN IF NOT EXISTS trust_tier      VARCHAR(32);
ALTER TABLE dl_attribute ADD COLUMN IF NOT EXISTS freshness_until TIMESTAMPTZ;
ALTER TABLE dl_attribute ADD COLUMN IF NOT EXISTS source_id       UUID;
ALTER TABLE dl_attribute ADD COLUMN IF NOT EXISTS revoked_at      TIMESTAMPTZ;

-- ── dl_event ───────────────────────────────────────────────────
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS visibility      VARCHAR(16);
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS trust_tier      VARCHAR(32);
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS freshness_until TIMESTAMPTZ;
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS source_id       UUID;
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS revoked_at      TIMESTAMPTZ;

-- ── dl_datapoint ───────────────────────────────────────────────
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS visibility      VARCHAR(16);
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS trust_tier      VARCHAR(32);
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS freshness_until TIMESTAMPTZ;
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS source_id       UUID;
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS revoked_at      TIMESTAMPTZ;

-- ── 索引 ───────────────────────────────────────────────────────
-- source_id：可见性 join 推导 + provenance 反查（按来源文件找其产出的所有 dl_* 行）
CREATE INDEX IF NOT EXISTS idx_dl_entity_source_id    ON dl_entity (source_id);
CREATE INDEX IF NOT EXISTS idx_dl_relation_source_id  ON dl_relation (source_id);
CREATE INDEX IF NOT EXISTS idx_dl_attribute_source_id ON dl_attribute (source_id);
CREATE INDEX IF NOT EXISTS idx_dl_event_source_id     ON dl_event (source_id);
CREATE INDEX IF NOT EXISTS idx_dl_datapoint_source_id ON dl_datapoint (source_id);

-- visibility：ACL WHERE 注入按 visibility 过滤（与 project_id 复合，先单列起步）
CREATE INDEX IF NOT EXISTS idx_dl_entity_visibility    ON dl_entity (visibility);
CREATE INDEX IF NOT EXISTS idx_dl_relation_visibility  ON dl_relation (visibility);
CREATE INDEX IF NOT EXISTS idx_dl_attribute_visibility ON dl_attribute (visibility);
CREATE INDEX IF NOT EXISTS idx_dl_event_visibility     ON dl_event (visibility);
CREATE INDEX IF NOT EXISTS idx_dl_datapoint_visibility ON dl_datapoint (visibility);

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 五表各新增 5 列（应每表返回 5 行：visibility/trust_tier/freshness_until/source_id/revoked_at）：
--    SELECT table_name, column_name FROM information_schema.columns
--      WHERE table_name IN ('dl_entity','dl_relation','dl_attribute','dl_event','dl_datapoint')
--        AND column_name IN ('visibility','trust_tier','freshness_until','source_id','revoked_at')
--      ORDER BY table_name, column_name;
-- 2) source_id 索引存在（应返回 5 行）：
--    SELECT indexname FROM pg_indexes WHERE indexname LIKE 'idx_dl_%_source_id';
-- 3) writer 回填后冒烟：
--    SELECT source_id, trust_tier FROM dl_datapoint WHERE source_id IS NOT NULL LIMIT 5;

-- ══════════════════════════════════════════════════════════════════════════════
-- [16/46] 数据层证据 · 033_dl_event_datapoint_fk.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 033_dl_event_datapoint_fk.sql
-- 数据层 M1-S4 · dl_event / dl_datapoint 补 entity 关联 + chunk/file/locator provenance 列。
--
-- 现状（029 逐行确认）：
--   * dl_event.participants = JSONB 名字数组（029:65），按名字串存，无 entity_id 关联；
--     **无 chunk_ids 列**（仅 entity/relation/attribute 有）。
--   * dl_datapoint.entity = TEXT（029:79），按名字串存，无 entity_id 外键；**无 chunk_ids 列**。
--   → ①图谱②chunk 互喂桥在事件/数据点维度断了；timeline/datapoints 按名字 jsonb_exists/= 匹配。
--
-- 本迁移加列（KAG「关系/事件/数据点一律按 entity_id 关联，不存 name 串」身份-证据两层）：
--   dl_event:
--     participant_ids BIGINT[]   参与者实体 id 数组（逻辑指 dl_entity.id；writer canon2id 解析回填）
--     chunk_ids       JSONB      来源 chunk id 数组（①②互喂桥；存真实 knowledge_embeddings PK）
--     file_id         UUID       来源文件 id（逻辑指 files.id）
--     locator         JSONB      原档定位 {page, char_span, excerpt}——可追踪闭环底层
--   dl_datapoint:
--     entity_id       BIGINT     所属实体 id（逻辑指 dl_entity.id；替代 entity TEXT 名字匹配）
--     chunk_ids       JSONB      来源 chunk id 数组
--     file_id         UUID       来源文件 id
--     locator         JSONB      原档定位 {page, char_span, excerpt}
--
-- 设计取舍（关键）：
--   * entity_id / participant_ids / file_id **先不加硬 FK 约束**——避免 dl_entity 全量重建（029:10
--     注释「先删后插全量重建」）时外键级联删空 dl_event/dl_datapoint，破坏「先打通形态、M4 再换
--     稳定 id」的分阶段策略（蓝图 M1-S4 ⚠）。仅建索引供 JOIN dl_entity by id。
--   * chunk_ids / locator 用 JSONB（与 029 既有 chunk_ids JSONB 一致），数组 / 结构皆可。
--   * 列可空——writer 解析 canonical→id 后回填；存量行（名字串）保留 entity/participants 原列不动。
--
-- 幂等：全部 ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS；可重放。

-- ── dl_event：补 participant_ids / chunk_ids / file_id / locator ──
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS participant_ids BIGINT[];
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS chunk_ids       JSONB NOT NULL DEFAULT '[]';
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS file_id         UUID;
ALTER TABLE dl_event ADD COLUMN IF NOT EXISTS locator         JSONB;

-- ── dl_datapoint：补 entity_id / chunk_ids / file_id / locator ──
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS entity_id BIGINT;
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS chunk_ids JSONB NOT NULL DEFAULT '[]';
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS file_id   UUID;
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS locator   JSONB;

-- ── 索引（无硬 FK，仅索引支撑 JOIN dl_entity by id + 按文件反查）──
-- dl_datapoint.entity_id：timeline/datapoints 查询从 entity=:name 改 JOIN dl_entity ON id 的连接键
CREATE INDEX IF NOT EXISTS idx_dl_datapoint_entity_id ON dl_datapoint (entity_id);
CREATE INDEX IF NOT EXISTS idx_dl_datapoint_file_id   ON dl_datapoint (file_id);

-- dl_event.participant_ids：GIN 数组索引，支撑「某实体参与的所有事件」按 id 数组成员查询
CREATE INDEX IF NOT EXISTS idx_dl_event_participant_ids ON dl_event USING gin (participant_ids);
CREATE INDEX IF NOT EXISTS idx_dl_event_file_id         ON dl_event (file_id);

-- ── 验证 SQL（迁移后手动核对）──
-- 1) dl_event 新增 4 列、dl_datapoint 新增 4 列：
--    SELECT table_name, column_name, data_type FROM information_schema.columns
--      WHERE (table_name = 'dl_event'     AND column_name IN ('participant_ids','chunk_ids','file_id','locator'))
--         OR (table_name = 'dl_datapoint' AND column_name IN ('entity_id','chunk_ids','file_id','locator'))
--      ORDER BY table_name, column_name;
--    预期 dl_event.participant_ids = ARRAY (bigint[])、locator/chunk_ids = jsonb；
--         dl_datapoint.entity_id = bigint。
-- 2) GIN 数组索引存在：
--    SELECT indexname FROM pg_indexes WHERE indexname = 'idx_dl_event_participant_ids';
-- 3) writer 改写后回归（应能按 id JOIN 拿到实体名）：
--    SELECT e.canonical FROM dl_datapoint d JOIN dl_entity e ON e.id = d.entity_id LIMIT 5;

-- ══════════════════════════════════════════════════════════════════════════════
-- [17/46] 数据层证据 · 034_embedding_model_version.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 034_embedding_model_version.sql
-- 数据层 M1-S5 · 向量列旁加 model/version 维度，支持新旧多版本共存做 A/B。
--
-- 现状：dl_entity.embedding vector(1024)（029:23）与 knowledge_embeddings.embedding 均为单一向量，
-- 无模型/版本标记；system_config['embedding_model'] 是单值（CLAUDE.md 架构说明）。换 embedding 模型
-- 或维度时，旧向量与新向量混在同列无法区分 → 无法灰度切换 / 回测召回。
--
-- 本迁移给两表各加：
--   embedding_model   VARCHAR(64)      产出该向量的模型名（如 'text-embedding-v3'）——检索按 model 过滤
--   embedding_version INT DEFAULT 1    向量版本号——同向量列多版本共存，检索默认只取当前 version
--
-- 借鉴：nano-graphrag「存储后端可热插拔」+ DeepDoc「多解析后端同契约可切」——
--   模型版本即「同向量列、多版本可切」，写入带 version，检索按 version 过滤。
--
-- 取舍：embedding_version DEFAULT 1 让存量行自动归入「v1」（即首版模型产出），新模型写 v2+；
--   embedding_model 可空（存量行模型未知，回填或留 NULL 由 writer/检索按当前 system_config 兜底）。
--
-- 幂等：全部 ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS；可重放。

-- ── dl_entity（①图谱路径实体向量）──
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS embedding_model   VARCHAR(64);
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS embedding_version INT DEFAULT 1;

-- ── knowledge_embeddings（②chunk 文本路径向量）──
ALTER TABLE knowledge_embeddings ADD COLUMN IF NOT EXISTS embedding_model   VARCHAR(64);
ALTER TABLE knowledge_embeddings ADD COLUMN IF NOT EXISTS embedding_version INT DEFAULT 1;

-- ── 索引（检索默认按当前 version 过滤；与既有 HNSW 向量索引正交）──
CREATE INDEX IF NOT EXISTS idx_dl_entity_emb_version ON dl_entity (embedding_version);
CREATE INDEX IF NOT EXISTS idx_knowledge_emb_version ON knowledge_embeddings (embedding_version);

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 两表各新增 2 列（应返回 4 行）：
--    SELECT table_name, column_name, column_default FROM information_schema.columns
--      WHERE table_name IN ('dl_entity','knowledge_embeddings')
--        AND column_name IN ('embedding_model','embedding_version')
--      ORDER BY table_name, column_name;
--    预期 embedding_version 的 column_default = 1。
-- 2) 多版本共存冒烟：写两条不同 version 后
--    SELECT DISTINCT embedding_version FROM dl_entity;   -- 应见多值
-- 3) 检索默认只取当前 version（业务侧验证：WHERE embedding_version = :current）。

-- ══════════════════════════════════════════════════════════════════════════════
-- [18/46] 数据层证据 · 035_knowledge_embeddings_locator.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 035_knowledge_embeddings_locator.sql
-- 数据层 M1-S6 · knowledge_embeddings 加 locator，承载 chunk 在原档的精确定位。
--
-- 现状：knowledge_embeddings 有 file_id / source_name / content_type / tsv（003），但**无 locator**——
-- chunk 无法回指原档页码/字符跨度，可追踪闭环（M5-S3/S4）缺底层；与 dl_* 的 chunk_ids 也未打通
-- （dl_* chunk_ids 存 youtu 8 位随机 hex，非 knowledge_embeddings PK，builder.py:62-64）。
--
-- 本迁移加：
--   locator JSONB    chunk 原档定位 {page, char_span, excerpt}（DeepDoc 出版面坐标时直接填）——
--                    与 dl_event/dl_datapoint.locator（033）同结构，引用点开取回原档段的依据。
--
-- 借鉴：RAGFlow「坐标内联标签 + remove_tag 双视图」——locator 是 {page, char_span} 简化版
-- （先不做 bbox），embedding/全文索引前过 remove_tag 取裸文本，locator 单存定位。纯字符串协议、
-- 零额外存储压力。
--
-- 幂等：ADD COLUMN IF NOT EXISTS；可重放。

-- ── knowledge_embeddings：加 locator ──────────────────────────────
ALTER TABLE knowledge_embeddings ADD COLUMN IF NOT EXISTS locator JSONB;

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 列已加（应返回 1 行，data_type = jsonb）：
--    SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_name = 'knowledge_embeddings' AND column_name = 'locator';
-- 2) 闭环冒烟：一条 dl_entity 的 chunk_ids[0] 能取回原文 + locator（M1-S6 改 chunk_ids 存真实 PK 后）：
--    SELECT chunk_text, locator FROM knowledge_embeddings WHERE id = :cid;

-- ══════════════════════════════════════════════════════════════════════════════
-- [19/46] 数据层评价 · 036_dl_evaluation_tables.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 036_dl_evaluation_tables.sql
-- 数据层 M1-S7 · 评价层两表 dl_rating + dl_opinion（投研特化，补 GraphRAG 家族空白）。
--
-- 背景：KAG/LightRAG/nano-graphrag 全家族纯事实抽取，评价被丢或混进自由文本 description
-- （不可结构化查询/聚合）。投研价值恰在判断：
--   * dl_rating  = 结构化评级（买入/增持/中性/减持/卖出 + 目标价 + 评级机构 + 日期），硬如 datapoint。
--   * dl_opinion = 论点（微软 GraphRAG claim_extraction 的投研特化版：holder/stance/aspect/claim）。
--
-- 本迁移**只建表**（含 UNIQUE + 索引），additive 幂等；writer persist 接口与抽取逻辑见 M1-S7 配套
-- （apps/datacenter/store/writer.py persist 接口 + M4-S11 opinions.py 抽取器），本步默认空表。
--
-- ACL/provenance 列与 dl_* 五表（032）同款：source_id / visibility / trust_tier，供共享层 ACL 注入。
-- 设计取舍：entity_id / source_id **不加硬 FK**（同 033 理由——dl_entity 全量重建避免级联删空），仅索引。
--
-- 幂等：CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS；可重放。

-- ── dl_rating（结构化评级：每家机构对某实体的一次评级 = 一行）──────────────────
CREATE TABLE IF NOT EXISTS dl_rating (
    id           BIGSERIAL   PRIMARY KEY,
    project_id   UUID        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    entity_id    BIGINT,                          -- 被评级实体 id（逻辑指 dl_entity.id，无硬 FK）
    rating       TEXT,                            -- 评级：买入/增持/中性/减持/卖出
    target_price NUMERIC,                         -- 目标价（数值，便于聚合/比较）
    rating_org   TEXT,                            -- 评级机构（如「中金公司」「摩根士丹利」）
    rating_date  DATE,                            -- 评级日期
    source_id    UUID,                            -- 来源文件 id（逻辑指 files.id）
    visibility   VARCHAR(16),                     -- 可见性档（personal/project/fund_wide）
    trust_tier   VARCHAR(32),                     -- 信任档（6 档，见 enums.py TrustTier）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 同机构同日对同实体的评级唯一（注：entity_id/rating_org/rating_date 含 NULL 时 PG 默认按 distinct
    -- 处理，不会拦截「均为 NULL」的多行——评级行正常路径三者非空，可写性优先）
    UNIQUE (project_id, entity_id, rating_org, rating_date)
);
-- 按项目 + 实体查该实体的全部评级（评级一致性 / 共识口径聚合）
CREATE INDEX IF NOT EXISTS idx_dl_rating_project_entity ON dl_rating (project_id, entity_id);

-- ── dl_opinion（论点：某持有人对某实体某维度的多空判断 + 主张）──────────────────
CREATE TABLE IF NOT EXISTS dl_opinion (
    id          BIGSERIAL   PRIMARY KEY,
    project_id  UUID        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    entity_id   BIGINT,                           -- 被论及实体 id（逻辑指 dl_entity.id，无硬 FK）
    holder      TEXT,                             -- 论点持有人（分析师/机构/作者）
    stance      TEXT,                             -- 立场：多 / 空 / 中
    aspect      TEXT,                             -- 维度：护城河 / 估值 / 风险 / 成长 / 竞争
    claim       TEXT,                             -- 主张原文（一句话观点）
    source_id   UUID,                             -- 来源文件 id（逻辑指 files.id）
    visibility  VARCHAR(16),                      -- 可见性档
    trust_tier  VARCHAR(32),                      -- 信任档
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 按项目 + 实体查该实体的全部论点（多空综述 / 「N 看多 M 看空」对账）
CREATE INDEX IF NOT EXISTS idx_dl_opinion_project_entity ON dl_opinion (project_id, entity_id);

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 两表存在：
--    SELECT table_name FROM information_schema.tables
--      WHERE table_name IN ('dl_rating','dl_opinion');
-- 2) dl_rating 列齐全（应含 id/project_id/entity_id/rating/target_price/rating_org/rating_date/
--    source_id/visibility/trust_tier/created_at）：
--    SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_name = 'dl_rating' ORDER BY ordinal_position;
-- 3) dl_opinion 列齐全（应含 id/project_id/entity_id/holder/stance/aspect/claim/source_id/
--    visibility/trust_tier/created_at）：
--    SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_name = 'dl_opinion' ORDER BY ordinal_position;
-- 4) UNIQUE + 索引存在：
--    SELECT indexname FROM pg_indexes
--      WHERE tablename IN ('dl_rating','dl_opinion')
--      ORDER BY tablename, indexname;
--    预期含 dl_rating 的 UNIQUE 约束索引 + idx_dl_rating_project_entity + idx_dl_opinion_project_entity。
-- 5) writer 冒烟：插一条假 rating / opinion 不报错（业务侧）。

-- ══════════════════════════════════════════════════════════════════════════════
-- [20/46] 数据层 ACL · 037_backfill_visibility.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 037_backfill_visibility.sql
-- 数据层 M2 · 存量 dl_* 行 visibility 回填默认 'project'（向后兼容关键步）。
--
-- 背景：032（dl_* 五表）/036（dl_rating + dl_opinion 两表）给 dl_* 七表加了 ACL 列
--   visibility VARCHAR(16)，但**故意不填默认值 / 不加 NOT NULL**（032 设计取舍）——让 M2
--   过滤注入按 NULL 走「保守可见 + 默认档」语义，writer 从抽取产物的 source 绑定回填，
--   避免存量行被强制改写。
--
-- 现在 M2 共享层 ACL WHERE 注入要按 visibility 过滤读：存量行（032/036 之前已由 datacenter
--   流水线写入的 dl_* 行）visibility 仍为 NULL。若不回填，这批历史数据在「按 visibility 精确
--   过滤」的读路径下行为依赖 NULL 兜底语义，跨档（personal/project/fund_wide）判定不确定。
--   本步把存量 NULL 统一回填为 files.visibility 的同款默认值 'project'（FileVisibility.PROJECT，
--   006 起 files.visibility 即 DEFAULT 'project'）——与「项目成员均可见」的现状语义一致，
--   是向后兼容（backward-compat）的关键步：历史数据落到确定且最贴合现状的可见性档。
--
-- 范围：仅 dl_* 七表（dl_entity / dl_relation / dl_attribute / dl_event / dl_datapoint /
--   dl_rating / dl_opinion）。
--   注：knowledge_embeddings（②chunk 文本路径）的可见性走 JOIN files 推导——files.visibility
--   自 006 起即 NOT NULL DEFAULT 'project'，无 NULL 存量，故**无需回填**；本脚本不触及它。
--
-- 幂等：每条 UPDATE 带 `WHERE visibility IS NULL`——已回填行（非 NULL）不再被改写，可任意重放。
--   后续新写入行由 writer 显式带 visibility，亦不会被本回填影响。

-- ── dl_entity ──────────────────────────────────────────────────
UPDATE dl_entity    SET visibility = 'project' WHERE visibility IS NULL;

-- ── dl_relation ────────────────────────────────────────────────
UPDATE dl_relation  SET visibility = 'project' WHERE visibility IS NULL;

-- ── dl_attribute ───────────────────────────────────────────────
UPDATE dl_attribute SET visibility = 'project' WHERE visibility IS NULL;

-- ── dl_event ───────────────────────────────────────────────────
UPDATE dl_event     SET visibility = 'project' WHERE visibility IS NULL;

-- ── dl_datapoint ───────────────────────────────────────────────
UPDATE dl_datapoint SET visibility = 'project' WHERE visibility IS NULL;

-- ── dl_rating ──────────────────────────────────────────────────
UPDATE dl_rating    SET visibility = 'project' WHERE visibility IS NULL;

-- ── dl_opinion ─────────────────────────────────────────────────
UPDATE dl_opinion   SET visibility = 'project' WHERE visibility IS NULL;

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 七表均无 NULL visibility 残留（每条应返回 0）：
--    SELECT count(*) FROM dl_entity    WHERE visibility IS NULL;
--    SELECT count(*) FROM dl_relation  WHERE visibility IS NULL;
--    SELECT count(*) FROM dl_attribute WHERE visibility IS NULL;
--    SELECT count(*) FROM dl_event     WHERE visibility IS NULL;
--    SELECT count(*) FROM dl_datapoint WHERE visibility IS NULL;
--    SELECT count(*) FROM dl_rating    WHERE visibility IS NULL;
--    SELECT count(*) FROM dl_opinion   WHERE visibility IS NULL;
-- 2) 存量行 visibility 分布（应全为 'project'，无 NULL）：
--    SELECT visibility, count(*) FROM dl_entity GROUP BY visibility;
--    （其余六表同）

-- ══════════════════════════════════════════════════════════════════════════════
-- [21/46] 数据层信任 · 038_trust_tier_6.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 038_trust_tier_6.sql
-- 数据层 M2-S2 · TrustTier 5 档 → 6 档对齐（CHECK 放开 + 存量数据重写）。
--
-- 背景：M0-S3 冻结信任档口径——设计文档与新 enums.py 用 6 档，027 迁移的 files.trust_tier
--   CHECK 与历史数据仍是旧 5 档。本迁移把 DB 拉齐到 6 档。
--
-- 旧 5 档（027 chk_files_trust_tier）→ 新 6 档（enums.py TrustTier）映射：
--     internal      → internal_official   （海尔内部权威）
--     external_paid → external_verified   （付费/官方外部，已签约可信）
--     external_free → web_low             （免费 web 检索，低信任）
--     agent_output  → agent_generated     （Agent 自动产物）
--     user_upload   → user_upload         （不变）
--   新增 verified（人工核验过的外部源）——旧数据无此值，由后置人工核验流程赋值，本迁移不产生。
--
-- 作用域：
--   * files 表——有 CHECK 约束（chk_files_trust_tier，027:42），需放开为 6 档 + 重写存量。
--   * dl_* 七表（dl_entity/dl_relation/dl_attribute/dl_event/dl_datapoint/dl_rating/dl_opinion）
--     ——trust_tier 仅 VARCHAR(32) 无 CHECK（032/036），故只重写存量值，无约束可改。
--   * system_config['data_layer'].sinkers[*].trust_tier 配置里的旧值（external_paid/external_free）
--     一并重写，使新沉淀直接落新档（与 sinker 默认 tier 映射的代码改动 M2-S2 配套，本迁移先把
--     配置数据拉齐，避免新写入又引入旧值）。
--
-- 执行顺序（关键）：先 DROP 旧 CHECK → 再 UPDATE 重写存量 → 最后 ADD 新 CHECK。
--   若先加新 CHECK 而存量仍是旧值，ADD CONSTRAINT 校验会失败；必须先把数据改成新值。
--
-- 幂等：
--   * DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT（先 DROP 再 ADD，可重放）。
--   * UPDATE 的 WHERE 只命中旧值（trust_tier IN 旧 5 档）——重放时存量已是新值，0 行命中，无副作用。
--   * 配置 JSON 用 replace 链按字符串替换旧 tier，重放时新值里已无旧子串，等价幂等。

-- ── 0. 防御性保证 files.trust_tier 列存在 ──────────────────────
-- 正常迁移顺序下 027 已建该列；此处 ADD COLUMN IF NOT EXISTS 仅作防御
-- （若 027 因故未跑而本迁移先到，下方 UPDATE / CHECK 不会因缺列硬失败）。
-- 幂等：列已存在则空操作。provenance / freshness_until 等 027 其余列不在本迁移职责内，不补。
ALTER TABLE files ADD COLUMN IF NOT EXISTS trust_tier VARCHAR(32);

-- ── 1. files：放开 CHECK（先 DROP，重写后再 ADD）────────────────
ALTER TABLE files
    DROP CONSTRAINT IF EXISTS chk_files_trust_tier;

-- ── 2. 重写存量 trust_tier（files + dl_* 七表）旧 5 档 → 新 6 档 ──
-- 单条 CASE 重写，WHERE 限定旧值集合：重放时旧值已清零 = 无命中。
UPDATE files SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier  -- user_upload 不变；理论不会命中（WHERE 已排除）
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_entity SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_relation SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_attribute SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_event SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_datapoint SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_rating SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

UPDATE dl_opinion SET trust_tier = CASE trust_tier
        WHEN 'internal'      THEN 'internal_official'
        WHEN 'external_paid' THEN 'external_verified'
        WHEN 'external_free' THEN 'web_low'
        WHEN 'agent_output'  THEN 'agent_generated'
        ELSE trust_tier
    END
    WHERE trust_tier IN ('internal', 'external_paid', 'external_free', 'agent_output');

-- ── 3. system_config['data_layer'].sinkers 配置里的旧 tier → 新 tier ──
-- 配置 value(JSONB) 内 sinkers[*].trust_tier 写死了 external_paid / external_free（027:161-167）。
-- 转 text 链式 replace 改两个旧值再转回 jsonb；重放时新值里已无旧子串，幂等。
-- 注：仅这两个旧值出现在 027 配置；internal/agent_output 未出现在 sinkers，无需替换。
UPDATE system_config
    SET value = REPLACE(
                    REPLACE(value::text, '"external_paid"', '"external_verified"'),
                    '"external_free"', '"web_low"'
                )::jsonb,
        updated_at = now()
    WHERE key = 'data_layer'
      AND (value::text LIKE '%"external_paid"%' OR value::text LIKE '%"external_free"%');

-- ── 4. files：重新加 6 档 CHECK（存量已是新值，校验通过）────────
ALTER TABLE files
    ADD CONSTRAINT chk_files_trust_tier CHECK (
        trust_tier IS NULL OR trust_tier IN (
            'internal_official',
            'external_verified',
            'verified',
            'user_upload',
            'web_low',
            'agent_generated'
        )
    );

-- ── 验证 SQL（迁移后手动核对）──
-- 1) CHECK 已是 6 档（定义里含新值、无旧值）：
--    SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'chk_files_trust_tier';
-- 2) 无旧值残留（files + dl_* 七表，每条应返回 0）：
--    SELECT count(*) FROM files        WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_entity    WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_relation  WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_attribute WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_event     WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_datapoint WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_rating    WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
--    SELECT count(*) FROM dl_opinion   WHERE trust_tier IN ('internal','external_paid','external_free','agent_output');
-- 3) 配置已重写为新档（应无旧子串）：
--    SELECT value FROM system_config WHERE key = 'data_layer';
-- 4) files trust_tier 分布（应只见新 6 档之一或 NULL）：
--    SELECT trust_tier, count(*) FROM files GROUP BY trust_tier;

-- ══════════════════════════════════════════════════════════════════════════════
-- [22/46] 审计日志 · 039_event_log_tables.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 039_event_log_tables.sql
-- 数据层 M2-S6 · 事件日志「四表」：扩 audit_logs + 新建 decision_logs / access_logs /
--   agent_session_logs。全部 append-only（只插不改不删）。
--
-- 作用：把「谁改了权限/可见性（前后值）/ 谁做了投决裁定（带证据）/ 谁检索命中了什么 /
--   agent 会话怎么跑的（trace+token）」落成永久可审计流水。「看得见但可追责」的底座。
--
-- ⚠ 列定义与 apps/server/models/audit.py 的 ORM **逐列对齐**（ORM 为应用层契约源）：
--     AuditLog（扩 before/after + visibility/trust 变更投影）
--     DecisionLog / AccessLog / AgentSessionLog（三新表）
--   列名 / 类型 / 可空 / FK 若与 ORM 不一致会导致 ORM 查询运行期报错，故本迁移严格跟随 ORM。
--
-- append-only 语义：四表只 INSERT，绝不 UPDATE / DELETE。
--   * 业务表写入 + audit 落盘建议同事务（M2-S6 配套 db/event_hooks.py 的 after_insert/update 钩子）。
--   * 物理 append-only 由本迁移末尾的 BEFORE UPDATE OR DELETE 触发器兜底（RAISE EXCEPTION），
--     ORM 层不暴露任何 update/delete 助手。触发器幂等（DROP IF EXISTS + CREATE）。
--
-- 分区：按蓝图先用普通表 + created_at 索引（「先普通表不分区」），数据量上来后再升级
--   PARTITION BY RANGE(created_at)。本迁移不分区。
--
-- 外键取舍：跟随 ORM —— user_id / project_id 用 ON DELETE SET NULL（主体清理后日志行仍保留，
--   仅置空关联），conversation_id 不加 FK（仅索引，可指向已归档/外部会话）。
--   decision/access/agent 行无 updated_at（append-only，无 onupdate 语义）。
--
-- 幂等：CREATE TABLE / INDEX IF NOT EXISTS + ADD COLUMN IF NOT EXISTS + 触发器 DROP/CREATE；可重放。

-- ── 1. audit_logs 扩 before/after + visibility/trust 变更投影 ─────
-- 现状（001:246）：audit_logs 有 detail JSONB，无结构化「变更前/后」。
-- ORM（audit.py AuditLog）M2-S6 扩展加 6 列：
--   before / after            JSONB        —— 变更前后关键字段整体快照（仅审计关注字段）
--   visibility_before/after   VARCHAR(16)  —— 可见性档变更投影（高频维度快捷过滤）
--   trust_tier_before/after   VARCHAR(32)  —— 信任档变更投影
-- 全部可空（旧行为 NULL；新写入由 event hook 按 diff 填）。不动既有列/索引。
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS before            JSONB;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS after             JSONB;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS visibility_before VARCHAR(16);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS visibility_after  VARCHAR(16);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS trust_tier_before VARCHAR(32);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS trust_tier_after  VARCHAR(32);

-- ── 2. decision_logs（投决/裁定事件，永久留证据链）───────────────
-- 对齐 ORM DecisionLog。核心 source_evidence_ids = 决策依据的稳定数据点 id 数组
-- （dl_datapoint.id / dl_event.id，BIGINT），**永久保留**——底层证据后续软撤也不影响决策当时引用链
-- （蓝图决策①：「引用」= agent_outputs.source_data_ids 内含的 dl_datapoint/dl_event/chunk id）。
-- decision_type 取值见 enums.DecisionType（kickoff/investment/adjudication/revocation）。
CREATE TABLE IF NOT EXISTS decision_logs (
    id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 决策发起人（可空：系统自动裁定无具体用户）
    user_id             UUID         REFERENCES users(id)    ON DELETE SET NULL,
    -- 决策所属项目（可空：跨项目 / 基金级裁定）
    project_id          UUID         REFERENCES projects(id) ON DELETE SET NULL,
    -- 决策类型（enums.DecisionType；DB 留 VARCHAR 灵活）
    decision_type       VARCHAR(64)  NOT NULL,
    -- 决策标的（被决策的实体/文件/项目 id 字符串，跨类型故 VARCHAR）
    subject_id          VARCHAR(64),
    -- 决策结论（通过/否决/暂缓/已撤 …）
    outcome             VARCHAR(64),
    -- 决策理由 / 裁定说明（自由文本）
    rationale           TEXT,
    -- ⭐ 引用证据链：稳定数据点 id 数组（JSONB；软撤旁路按建立时间 < revoked_at 判定）
    source_evidence_ids JSONB,
    -- 附加结构化明细（投票分布 / 条件 / 关联会议 id 等）
    detail              JSONB,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);
-- created_at 索引（ORM 标 index=True）：append-only 按时间倒序翻流水
CREATE INDEX IF NOT EXISTS idx_decision_logs_created  ON decision_logs (created_at);
-- 回溯：按发起人 / 项目 / 类型
CREATE INDEX IF NOT EXISTS idx_decision_logs_user     ON decision_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_decision_logs_project  ON decision_logs (project_id);
CREATE INDEX IF NOT EXISTS idx_decision_logs_type     ON decision_logs (decision_type, created_at);

-- ── 3. access_logs（检索命中溯源，一次 search_hit 一行）──────────
-- 对齐 ORM AccessLog。记「谁/何时/用什么 query/命中哪条证据/得分」。
-- 注（蓝图决策①）：一次性浏览（access_log）**不构成「引用」**——软撤后即不可见，不进引用旁路。
-- resource_type 取值见 enums.AuditResourceType（chunk/datapoint/event/entity …）。
CREATE TABLE IF NOT EXISTS access_logs (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 访问者（可空：匿名/系统检索）
    user_id       UUID         REFERENCES users(id)    ON DELETE SET NULL,
    -- 检索发生的项目上下文（ACL 并集「我的项目」判定依据）
    project_id    UUID         REFERENCES projects(id) ON DELETE SET NULL,
    -- 被命中证据类型（enums.AuditResourceType）
    resource_type VARCHAR(64)  NOT NULL,
    -- 被命中证据 id（chunk PK / dl_datapoint.id / dl_event.id，跨类型故 VARCHAR）
    resource_id   VARCHAR(64),
    -- 触发命中的查询文本（截断存储，回放检索意图）
    query_text    TEXT,
    -- 命中时相似度/排序分（粗排诊断；ORM 为 float → double precision）
    score         DOUBLE PRECISION,
    -- 附加明细（命中通道 vector/bm25/rrf、trust_tier、freshness 是否过期等）
    detail        JSONB,
    ip_address    VARCHAR(45),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_access_logs_created   ON access_logs (created_at);
CREATE INDEX IF NOT EXISTS idx_access_logs_user      ON access_logs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_access_logs_project   ON access_logs (project_id);
-- 按资源回溯「谁访问过这条证据」（软撤审计、热点统计）
CREATE INDEX IF NOT EXISTS idx_access_logs_resource  ON access_logs (resource_type, resource_id);

-- ── 4. agent_session_logs（agent 会话级 trace + token）──────────
-- 对齐 ORM AgentSessionLog。一次会话/一轮一行，trace_id 串起端到端调用，token 计量做成本归因。
CREATE TABLE IF NOT EXISTS agent_session_logs (
    id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 关联用户（可空：系统级/后台任务触发的无会话调用）
    user_id           UUID         REFERENCES users(id) ON DELETE SET NULL,
    -- 关联会话（可空，不加 FK —— 可指向已归档/外部会话，仅索引）
    conversation_id   UUID,
    -- trace_id：一次端到端调用的全局关联键（跨工具/子智能体），调用链回放锚点
    trace_id          VARCHAR(64)  NOT NULL,
    -- 角色/阶段标识（main/subagent/tool …），分通道聚合
    role              VARCHAR(32),
    -- token 计量（成本归因；可空：流式中途/异常未结算）
    prompt_tokens     INTEGER,
    completion_tokens INTEGER,
    total_tokens      INTEGER,
    -- 模型标识（多模型成本拆分）
    model             VARCHAR(64),
    -- 附加 trace 明细（耗时/工具调用计数/错误等）
    detail            JSONB,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_agent_session_logs_created  ON agent_session_logs (created_at);
-- ORM 标 index=True 的两列：conversation_id / trace_id
CREATE INDEX IF NOT EXISTS idx_agent_session_logs_conv     ON agent_session_logs (conversation_id);
CREATE INDEX IF NOT EXISTS idx_agent_session_logs_trace    ON agent_session_logs (trace_id);
CREATE INDEX IF NOT EXISTS idx_agent_session_logs_user     ON agent_session_logs (user_id, created_at);

-- ── 5. append-only 物理兜底：禁 UPDATE / DELETE（触发器 RAISE）────
-- ORM 文档（audit.py）声明「物理 append-only 由迁移 039 的触发器兜底」。这里用一个公共触发器函数
-- 对四表统一拦截 UPDATE / DELETE —— 任何修改/删除直接抛错（审计流水不可篡改）。
-- 注：DDL（DROP TABLE / 分区迁移）不走行级触发器，不受影响；如需归档清理可临时 DISABLE TRIGGER。
-- 幂等：CREATE OR REPLACE FUNCTION + 每表 DROP TRIGGER IF EXISTS 再 CREATE。
CREATE OR REPLACE FUNCTION reject_log_mutation()
RETURNS TRIGGER AS $$
    BEGIN
        RAISE EXCEPTION 'append-only 日志表 % 禁止 % 操作（仅允许 INSERT）', TG_TABLE_NAME, TG_OP;
    END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_logs_append_only ON audit_logs;
CREATE TRIGGER trg_audit_logs_append_only
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION reject_log_mutation();

DROP TRIGGER IF EXISTS trg_decision_logs_append_only ON decision_logs;
CREATE TRIGGER trg_decision_logs_append_only
    BEFORE UPDATE OR DELETE ON decision_logs
    FOR EACH ROW EXECUTE FUNCTION reject_log_mutation();

DROP TRIGGER IF EXISTS trg_access_logs_append_only ON access_logs;
CREATE TRIGGER trg_access_logs_append_only
    BEFORE UPDATE OR DELETE ON access_logs
    FOR EACH ROW EXECUTE FUNCTION reject_log_mutation();

DROP TRIGGER IF EXISTS trg_agent_session_logs_append_only ON agent_session_logs;
CREATE TRIGGER trg_agent_session_logs_append_only
    BEFORE UPDATE OR DELETE ON agent_session_logs
    FOR EACH ROW EXECUTE FUNCTION reject_log_mutation();

-- ⚠ audit_logs 历史上由 001 的 update_updated_at_column() 触发器在 UPDATE 时刷 updated_at。
--    本表 append-only 后不会再 UPDATE，但为避免「BEFORE UPDATE 两个触发器」语义混淆，
--    显式移除 audit_logs 上的 updated_at 触发器（若存在）。updated_at 列保留（不破坏 001 结构）。
DROP TRIGGER IF EXISTS update_audit_logs_updated_at ON audit_logs;

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 三新表存在：
--    SELECT table_name FROM information_schema.tables
--      WHERE table_name IN ('decision_logs','access_logs','agent_session_logs');
-- 2) audit_logs 已含 6 个新列：
--    SELECT column_name FROM information_schema.columns
--      WHERE table_name='audit_logs'
--        AND column_name IN ('before','after','visibility_before','visibility_after','trust_tier_before','trust_tier_after');
-- 3) decision_logs.source_evidence_ids 为 jsonb：
--    SELECT data_type FROM information_schema.columns
--      WHERE table_name='decision_logs' AND column_name='source_evidence_ids';
-- 4) created_at 索引存在（3 条）：
--    SELECT indexname FROM pg_indexes
--      WHERE indexname IN ('idx_decision_logs_created','idx_access_logs_created','idx_agent_session_logs_created');
-- 5) append-only 生效：UPDATE decision_logs SET outcome='x' → 应抛「禁止 UPDATE」异常；
--    INSERT 一行带 source_evidence_ids 应成功。

-- ══════════════════════════════════════════════════════════════════════════════
-- [23/46] 共享授权 · 040_share_grants.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 040_share_grants.sql
-- 数据层 M2-S7 / M2-S5 · 点对点共享 grant 表 + files 软撤列 + 收回策略配置。
--
-- 背景（知识库分级与共享-设计分析.md §5）：
--   「共享 = 改一列」改造把 personal→project / project→fund_wide 退化成 UPDATE visibility，
--   但单一 visibility 列只能表达「三级」，无法表达「把某文件点对点共享给另一个具体项目 / 白名单
--   用户」这类长尾。本表 share_grants 兜这条长尾：一行 = 一条显式授权（file × grantee）。
--   读路径 ACL WHERE 的并集里「我 ∈ 显式 grant」即查本表（M2-S1 注入，本步只建表 + 写入）。
--
--   收回 = 软撤（§5 拍定，默认策略）：停新访问、留 audit、标 revoked_at；已存在的引用（产物
--   溯源链 source_data_ids / grant 行，建立时间 < revoked_at）照常解析。软撤落在两处：
--     ① files.revoked_at —— 整文件维度收回（把已 relabel 到 project/fund_wide 的文件撤回）；
--     ② share_grants.revoked_at —— 单条点对点授权维度收回。
--   032 已给 dl_* 五表加了 revoked_at；**files 表此前无此列**（全仓 grep 确认），本步补上。
--
-- 三策略走 system_config['data_layer'].revoke_policy（默认 soft）：
--   soft（默认）/ block_if_referenced / hard —— 见文末 data_layer 配置回填。
--
-- 幂等：所有 DDL 用 IF NOT EXISTS；config 回填用 jsonb 合并 ON CONFLICT DO UPDATE（不覆盖既有键）。
-- 验证 SQL 在文件末尾。


-- ── 1. files 表补 revoked_at（整文件维度软撤，M2-S5）──────────────
-- NULL = 未撤（默认）；有值 = 该时刻起停新访问。与 dl_* 的 revoked_at（032）同款语义，
-- 让「文件」与「文件派生的证据行」用同一把软撤钥匙。
ALTER TABLE files ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

COMMENT ON COLUMN files.revoked_at IS
    'M2-S5 软撤时间戳：NULL=未撤，有值=该时刻起停新访问（发现路径不可见）；已存在引用按时间戳 gate 旁路解析';

CREATE INDEX IF NOT EXISTS idx_files_revoked_at
    ON files (revoked_at) WHERE revoked_at IS NOT NULL;


-- ── 2. share_grants 表（点对点 / 白名单显式授权，M2-S7）────────────
-- 一行 = 一条显式授权：把 file_id 授予 grantee_project_id（项目维度）或 grantee_user_id
-- （白名单用户维度），二者至少一个非空（CHECK 兜）。共享**仍不重嵌 chunks**（grant 只加授权行，
-- 物理文件/向量不动），与「共享=引用不复制」铁律一致。
CREATE TABLE IF NOT EXISTS share_grants (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id             UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    -- 授权对象：项目维度 / 用户维度，至少一个非空
    grantee_project_id  UUID REFERENCES projects(id) ON DELETE CASCADE,
    grantee_user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
    -- 授权人（owner / admin），SET NULL 保留授权历史
    granted_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    -- 软撤时间戳：NULL=有效；有值=该授权已收回（§5 软撤），建立时间 < revoked_at 的引用仍解析
    revoked_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 至少授予一个对象
    CONSTRAINT share_grants_grantee_present CHECK (
        grantee_project_id IS NOT NULL OR grantee_user_id IS NOT NULL
    )
);

-- 防重复授权：同一 file × 同一 grantee（项目或用户）只保留一条有效 grant。
-- 用部分唯一索引（仅约束 grantee 非空那一维），允许同 file 同时授项目 + 授用户。
CREATE UNIQUE INDEX IF NOT EXISTS uq_share_grants_file_project
    ON share_grants (file_id, grantee_project_id)
    WHERE grantee_project_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_share_grants_file_user
    ON share_grants (file_id, grantee_user_id)
    WHERE grantee_user_id IS NOT NULL;

-- 读路径 ACL 并集查询入口：按 grantee 维度命中有效 grant（revoked_at IS NULL 由查询侧带）。
CREATE INDEX IF NOT EXISTS idx_share_grants_grantee_project
    ON share_grants (grantee_project_id) WHERE grantee_project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_share_grants_grantee_user
    ON share_grants (grantee_user_id) WHERE grantee_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_share_grants_file_id
    ON share_grants (file_id);

COMMENT ON TABLE share_grants IS
    'M2-S7 点对点 / 白名单显式授权：file × grantee（项目或用户），共享=加授权行不重嵌 chunks；revoked_at 软撤';
COMMENT ON COLUMN share_grants.revoked_at IS
    'M2-S5 软撤：NULL=有效；有值=已收回，仅 created_at < revoked_at 的引用可旁路解析';


-- ── 3. data_layer 配置补 revoke_policy（M2-S5 三策略，默认 soft）────
-- 软撤 / 有引用就拦 / 硬撤断链。读取走 sinkers/base.py:load_data_layer_config（已存在）。
-- 不覆盖既有 data_layer 键，仅在缺 revoke_policy 时补默认（jsonb || 右合并保留已有键）。
UPDATE system_config
   SET value = jsonb_set(
           COALESCE(value, '{}'::jsonb),
           '{revoke_policy}',
           '"soft"'::jsonb,
           true  -- create_missing：缺则建，存在则不动（下行 WHERE 已保证仅缺时执行）
       ),
       updated_at = now()
 WHERE key = 'data_layer'
   AND NOT (COALESCE(value, '{}'::jsonb) ? 'revoke_policy');  -- 已有 revoke_policy 则不改（可重放；NULL value 也回填）

-- data_layer 配置行不存在时（极端情况，027 未跑）兜底建一行最小配置带 revoke_policy。
INSERT INTO system_config (id, key, value, description, category)
SELECT
    gen_random_uuid(),
    'data_layer',
    '{"sinkers": {}, "default_action": "passthrough", "revoke_policy": "soft"}'::jsonb,
    '数据层 v3.0 飞轮配置（040 兜底建行，含收回策略）',
    'general'
WHERE NOT EXISTS (SELECT 1 FROM system_config WHERE key = 'data_layer');


-- ── 验证 SQL（迁移后手动核对）──
-- 1) files 多出 revoked_at 列：
--    SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_name = 'files' AND column_name = 'revoked_at';
-- 2) share_grants 表与索引存在：
--    \d share_grants
-- 3) CHECK 生效：插一行 grantee 全空应被拒：
--    INSERT INTO share_grants (file_id) VALUES (gen_random_uuid());  -- 期望报错
-- 4) revoke_policy 已就位（应为 "soft"）：
--    SELECT value -> 'revoke_policy' FROM system_config WHERE key = 'data_layer';

-- ══════════════════════════════════════════════════════════════════════════════
-- [24/46] 数据层配置 · 041_data_layer_per_seat_sources.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 041_data_layer_per_seat_sources.sql（原 038，2026-06-04 因 038 与 trust_tier_6 撞号重编为 041）
-- 数据层 M2-S3 · system_config['data_layer'] 增补 per_seat_sources 列表（按席位授权源白名单）。
--
-- 背景（决策②，2026-06-03 已定）：8 源全部公司级订阅 → vendor 沉淀默认 visibility='fund_wide'。
--   sinker（base.resolve_visibility / is_per_seat_source）读 data_layer.per_seat_sources 判定：
--     · slug 不在列表 → fund_wide（全员可见，公司级订阅的终态默认）
--     · slug 在列表   → 降级 project（该源按席位授权，须配套 granted_user_ids）
--   列表当前留空 = 全 fund_wide，是**无损默认即终态**。一旦未来核出某源是按席位订阅，
--   把它的 slug 加进本列表即可，无需改代码。
--
-- 兼容性：base.is_per_seat_source 已用 `config.get("per_seat_sources") or []` 安全兜底——
--   即使本 key 缺失，运行时也按空列表（全 fund_wide）走。本迁移把该约定**显式落库**，
--   让配置自描述、admin 面板可见可改，避免"靠代码默认隐式生效"。
--
-- 幂等：仅当 data_layer 配置中尚无 per_seat_sources 键时才注入空数组（`?` 存在性判断）；
--   已存在（含运维已填过值）则不动——可任意重放，绝不重置运维设置。

UPDATE system_config
SET value = value || '{"per_seat_sources": []}'::jsonb,
    updated_at = now()
WHERE key = 'data_layer'
  AND NOT (value ? 'per_seat_sources');

-- ── 验证 SQL（迁移后手动核对）──
-- 1) 确认 per_seat_sources 键已存在且为数组（空数组即终态默认）：
--    SELECT value -> 'per_seat_sources' AS per_seat_sources
--      FROM system_config WHERE key = 'data_layer';
--    -- 期望输出: []
-- 2) 重放本迁移不应改变已填值（先手动 UPDATE 塞一个 slug 再重放，值不应被清空）。

-- ══════════════════════════════════════════════════════════════════════════════
-- [25/46] 数据层配置 · 042_fix_jingzhun_slug.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 042_fix_jingzhun_slug.sql
-- M3-S4 配置修正:system_config['data_layer'].sinkers 里把 `jingzhundata:*` 改成 `jingzhun:*`。
--
-- 背景:027_data_layer_v3_kickoff.sql:172 写的 sinker 策略 key 是 `jingzhundata:*`,但
-- vendor_definitions / VendorHandlerType.CUSTOM_JINGZHUN 实际 vendor_slug 是 `jingzhun`
-- (见 vendor_proxy/jingzhun.py)。slug 不一致 → resolve_sinker_policy 匹配不到 `jingzhun:*`
-- → 鲸准回落 default_action=passthrough,**沉淀策略形同虚设**。本迁移把 key 对齐为 `jingzhun:*`。
--
-- 幂等:仅当存在错误 key 时才改写(IF EXISTS via WHERE ? 判断);ON CONFLICT 语义由
-- UPDATE 自身的"重复执行结果一致"保证(jsonb 删旧 key + 加新 key,再跑一次是 no-op)。
-- 已有正确配置(旧 key 不存在)时本迁移不动数据。

UPDATE system_config
SET
    -- jsonb 操作:在 sinkers 对象上「删除 jingzhundata:* 键」后「写入 jingzhun:* 键」。
    -- 保留原策略内容(action/trust_tier/ttl_days),仅换 key 名。
    value = jsonb_set(
        value #- '{sinkers,jingzhundata:*}',                 -- 1) 删旧 key
        '{sinkers,jingzhun:*}',                              -- 2) 在 jingzhun:* 写入
        -- 取旧 key 策略并把过时的 trust_tier='external_paid'(027 老 5 档)归一为
        -- 'external_verified'(038 新 6 档),避免 resolve_trust_tier 用旧值 TrustTier() 抛错。
        COALESCE(
            (value #> '{sinkers,jingzhundata:*}')
                || jsonb_build_object('trust_tier', 'external_verified'),
            value #> '{sinkers,jingzhun:*}',                 --    若已被改过则用现有 jingzhun:* 值
            '{"action": "ingest", "trust_tier": "external_verified", "ttl_days": 180}'::jsonb
            -- 兜底默认(旧/新 key 都缺时):鲸准=付费结构化源,经核验外部档,半年 TTL
        ),
        true                                                  -- create_missing=true,key 不存在则新建
    ),
    updated_at = now()
WHERE key = 'data_layer'
  -- 仅当旧的错误 key 仍存在时才执行,避免对已修正配置反复写(重放安全)
  AND value #> '{sinkers,jingzhundata:*}' IS NOT NULL;

-- ── 验证 SQL（迁移后手动核对）──
-- SELECT value #> '{sinkers,jingzhun:*}'     AS jingzhun_policy,      -- 应为 ingest 策略 jsonb
--        value #> '{sinkers,jingzhundata:*}' AS old_key_should_be_null
-- FROM system_config WHERE key = 'data_layer';
--   预期:jingzhun_policy 非空(action=ingest...),old_key 为 NULL(已删除)。

-- ══════════════════════════════════════════════════════════════════════════════
-- [26/46] 数据层配置 · 043_normalize_data_layer_trust_tiers.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 043_normalize_data_layer_trust_tiers.sql
-- M3-S4 配置收口:把 system_config['data_layer'].sinkers 里残留的旧 5 档信任名归一为 6 档，
--   并把 em_saas 从 passthrough 翻成结构化 ingest（Phase2 已为它建了结构化映射器）。
--
-- 背景（为何必须有这条迁移）：
--   · 027 kickoff 给各源 sinker policy 写死了旧 5 档 trust_tier：
--       hibor/mofoun/djyanbao/oxvalueai = external_paid，bocha = external_free。
--   · 038 升 6 档时只重写了 files 表的数据 + CHECK，**没动 system_config 这份 JSONB 配置**。
--   · M3 给这 6 源都装了 sinker/mapper 后，base.resolve_trust_tier 会对 policy['trust_tier']
--     调 TrustTier(explicit)。explicit='external_paid'/'external_free' 在 6 档枚举里已不存在
--     → **ValueError 运行时崩**（任何一次这些源的沉淀都会炸，含 hibor）。
--   · 042 已就 jingzhun 一项做了归一，本迁移把其余源一次性扫平 + 收尾 em_saas。
--
-- 归一映射（与 enums.py TrustTier 6 档 + 038 同口径）：
--   external_paid → external_verified  （付费/官方外部：研报/估值/财务结构化源）
--   external_free → web_low            （免费 web 检索：博查）
--   其余档位（已是 6 档新名 / 无 trust_tier）原样不动。
--
-- 幂等：① 档名归一用「仅当值仍是旧档时才覆盖」（jsonb_object_agg 重建，旧档扫完即无）；
--       ② em_saas 翻档用 WHERE 守卫（仅当仍是 passthrough 时才改）。两段可任意重放。
--
-- ⚠ 运行时缓存：base.load_data_layer_config 有进程级缓存（_data_layer_cache）。本迁移改库后，
--   在跑的 server 进程需调 invalidate_data_layer_cache()（或重启）才会读到新配置。
--   本地 A/B 重置或冷启动天然读新值，无需额外动作。


-- ── 1. 档名归一：扫 sinkers 对象，逐 policy 重映射过时 trust_tier ──────────────
--   用 jsonb_object_agg 在 sinkers 的每个 (key→policy) 上做 CASE 重映射，整体回写 sinkers。
UPDATE system_config
SET
    value = jsonb_set(
        value,
        '{sinkers}',
        (
            SELECT jsonb_object_agg(
                s.cfg_key,
                CASE s.cfg_pol ->> 'trust_tier'
                    WHEN 'external_paid' THEN s.cfg_pol || '{"trust_tier": "external_verified"}'::jsonb
                    WHEN 'external_free' THEN s.cfg_pol || '{"trust_tier": "web_low"}'::jsonb
                    ELSE s.cfg_pol
                END
            )
            FROM jsonb_each(system_config.value -> 'sinkers') AS s(cfg_key, cfg_pol)
        )
    ),
    updated_at = now()
WHERE key = 'data_layer'
  AND value -> 'sinkers' IS NOT NULL
  -- 仅当确有旧档残留时才重写（重放安全：扫平后此条件为假，不再写）
  AND EXISTS (
      SELECT 1 FROM jsonb_each(system_config.value -> 'sinkers') AS s(cfg_key, cfg_pol)
      WHERE s.cfg_pol ->> 'trust_tier' IN ('external_paid', 'external_free')
  );


-- ── 2. em_saas:* 从 passthrough 翻成结构化 ingest（激活 Phase2 的 em_saas 映射器）──────
--   原 027 把 em_saas 配 passthrough（"二级市场/行情类时效短不沉淀"）。M3-S3 已为东财建
--   结构化映射器（mappers/em_saas.py：财报三表/指标 → datapoint 带 period），且映射器自带
--   "单表期间列 >24 视为逐日行情整表跳过"的保护——故翻成 ingest 后，财报快照走结构化入 dl_*，
--   真·逐日行情仍被映射器自身丢弃，不污染。trust=external_verified（东财官方数据）。
--   幂等：仅当仍是 passthrough 时才翻（已翻过则 action≠passthrough，WHERE 假，不重写）。
UPDATE system_config
SET
    value = jsonb_set(
        value,
        '{sinkers,em_saas:*}',
        '{"action": "ingest", "trust_tier": "external_verified", "ttl_days": 180}'::jsonb,
        true  -- create_missing=true：键不存在也写入
    ),
    updated_at = now()
WHERE key = 'data_layer'
  AND value #>> '{sinkers,em_saas:*,action}' = 'passthrough';


-- ── 验证 SQL（迁移后手动核对）──────────────────────────────────────────────
-- 1) 确认 sinkers 里再无旧档名（应返回 0 行）：
--    SELECT s.key, s.value ->> 'trust_tier' AS tier
--      FROM system_config sc, jsonb_each(sc.value -> 'sinkers') AS s(key, value)
--     WHERE sc.key = 'data_layer'
--       AND s.value ->> 'trust_tier' IN ('external_paid', 'external_free');
--    -- 期望：0 行
-- 2) 抽查几个源已是新档：
--    SELECT s.key, s.value ->> 'action' AS action, s.value ->> 'trust_tier' AS tier
--      FROM system_config sc, jsonb_each(sc.value -> 'sinkers') AS s(key, value)
--     WHERE sc.key = 'data_layer' AND s.key IN ('hibor:list','bocha:*','em_saas:*');
--    -- 期望：hibor:list=external_verified / bocha:*=web_low / em_saas:*=ingest+external_verified

-- ══════════════════════════════════════════════════════════════════════════════
-- [27/46] 数据层身份 · 044_dl_entity_global_identity.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 044_dl_entity_global_identity.sql
-- 数据层 M4-C / M4-S1+S2+S3 · dl_entity 身份层去 project_id 硬隔离 + scope(canonical/provisional)。
--
-- ⚠⚠ 全数据层最危险、不可逆的一步：身份层从「按 project_id 硬隔离」改「全局共享 + scope carve-out」。
--    现状 dl_entity 每个项目各建各的实体（UNIQUE(project_id,canonical,etype)），M2 的 ACL 安全门
--    建在「证据层按 project_id 隔离」之上。本迁移**只动身份层 dl_entity**：
--      · 证据层（dl_relation / dl_attribute / dl_event / dl_datapoint）的 project_id 列**一字不动**
--        —— 它是 substance 隔离的主承重墙（queries.py 的 _acl_gate 按 visibility+project_id 过滤）；
--      · dl_entity 去 project_id 隔离、加 scope，canonical 行 project_id 置 NULL。
--    读路径 scope-gate 改写见 Phase2（queries.py），本迁移只把存量数据安全迁到新身份模型。
--
-- ── 身份模型（与 enums.EntityScope / writer.persist_store 三处一致）──────────────
--   scope VARCHAR(16)：
--     'canonical'   全局共享身份 —— project_id=NULL，全局唯一 UNIQUE(canonical,etype) WHERE scope='canonical'；
--     'provisional' 私有临时身份 —— 保留 project_id（owning 项目），仅该项目可见（隐形标的兜这）。
--   存量赋值规则（**安全合并**，不泄漏新信息）：
--     · (canonical, etype) 出现在 **≥2 个不同 project** → 合并成 1 行 canonical：选一个 id 保留
--       （取 MIN(id) 稳定可复现），其余行的 4 类证据外键全部重指到保留 id，再删多余实体行。
--       理由：≥2 个团队本就各自都有该实体，合并只是去重，不把任一方的隐形标的暴露给另一方。
--     · (canonical, etype) 只出现在 **1 个 project** → scope='provisional'，保留 project_id（留私有）。
--
-- ── 4 类证据外键重指（旧 id → 保留 id）──────────────────────────────────────
--   dl_relation.src_id / dl_relation.dst_id   （硬 FK ON DELETE CASCADE，029:35,37）
--   dl_attribute.entity_id                    （硬 FK ON DELETE CASCADE，029:50）
--   dl_datapoint.entity_id                    （软列无 FK，033:38）
--   dl_event.participant_ids（BIGINT[] 数组元素）（软列无 FK，033:32）
--   关键不冲突论证：证据行**保留各自 project_id**；同一 (canonical,etype) 组内，每个项目至多 1 个旧
--   实体 id（旧 UNIQUE(project_id,canonical,etype) 保证），故重指后**不产生项目内 dl_relation 唯一键
--   (project_id,src_id,relation,dst_id) 冲突、不产生自环**（一条关系的两端属同一组 ⇒ 在同项目内本就是
--   同一实体，不可能是两个不同旧 id）。跨项目两行 relation 因 project_id 不同天然不撞。
--
-- 幂等 + 可重放：scope 列 ADD IF NOT EXISTS；合并用临时映射表（每次重建）；重指/删除均对「仍存在的
--   多余行」生效（已合并过的二次执行映射表为空 → 全部 no-op）。末尾附验证 SQL。

-- ════════════════════════════════════════════════════════════════════════════
-- 0) scope 列 + 放开 project_id 硬约束（canonical 行需 project_id=NULL）
-- ════════════════════════════════════════════════════════════════════════════

-- scope：身份归属档（VARCHAR(16) 与 enums.EntityScope 同口径；本迁移末尾给所有行赋非空值，
-- 但列本身先可空以便分步回填，赋值完成后再加 NOT NULL）。
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS scope VARCHAR(16);

-- 放开 project_id NOT NULL：canonical 行置 NULL（不再参与隔离）；provisional 仍写 project_id。
ALTER TABLE dl_entity ALTER COLUMN project_id DROP NOT NULL;

-- 去 project_id → projects(id) 的硬外键：canonical 行 project_id=NULL 与该 FK 不冲突（NULL 不被 FK 校验），
-- 但 FK 的 ON DELETE CASCADE 语义对 canonical（无属主项目）已无意义；且全局实体不应随某项目删除被级联清。
-- FK 名为建表时自动生成（dl_entity_project_id_fkey），用 DO 块按名条件删除（幂等：不存在则跳过）。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'dl_entity'
          AND constraint_name = 'dl_entity_project_id_fkey'
          AND constraint_type = 'FOREIGN KEY'
    ) THEN
        ALTER TABLE dl_entity DROP CONSTRAINT dl_entity_project_id_fkey;
    END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 1) 构建「旧 id → 保留 id」映射表（仅 ≥2 项目的组进入；保留 id = 组内 MIN(id)）
-- ════════════════════════════════════════════════════════════════════════════
-- 临时表（会话级）：每次执行重建，承载本次需要合并的多余行→保留行映射。
DROP TABLE IF EXISTS _dl_entity_merge_map;
CREATE TEMP TABLE _dl_entity_merge_map (
    old_id  BIGINT PRIMARY KEY,   -- 待删的多余实体行 id
    keep_id BIGINT NOT NULL       -- 该 (canonical,etype) 组保留的全局 canonical id
);

-- 仅取「(canonical,etype) 横跨 ≥2 个不同 project」的组：
--   · keep_id = 组内 MIN(id)（稳定、可复现）；
--   · 把组内**除 keep 外**的每一行 id 作为 old_id 入映射（old_id≠keep_id）。
-- 已合并过的二次执行：此时同组只剩 keep 一行（canonical，project_id=NULL），COUNT(DISTINCT project_id)
--   退化（NULL 不计入 distinct）→ 不再满足 ≥2 → 映射为空 → 后续全 no-op，故幂等。
WITH grp AS (
    SELECT
        canonical,
        etype,
        MIN(id) AS keep_id,
        COUNT(DISTINCT project_id) AS proj_cnt
    FROM dl_entity
    -- 只对仍带 project_id 的行分组（已晋升的 canonical 行 project_id=NULL，不参与再次合并）
    WHERE project_id IS NOT NULL
    GROUP BY canonical, etype
)
INSERT INTO _dl_entity_merge_map (old_id, keep_id)
SELECT e.id, g.keep_id
FROM dl_entity e
JOIN grp g
  ON g.canonical = e.canonical AND g.etype = e.etype
WHERE g.proj_cnt >= 2          -- ≥2 个不同项目才合并成全局 canonical
  AND e.id <> g.keep_id        -- 保留行自身不入映射（不重指自己、不删自己）
  AND e.project_id IS NOT NULL;

-- ════════════════════════════════════════════════════════════════════════════
-- 2) 4 类证据外键一次性批量重指（旧 id → 保留 id；UPDATE ... FROM map，不在循环里逐条）
-- ════════════════════════════════════════════════════════════════════════════
-- 证据行**保留各自 project_id 不动**（只改指向的实体 id）。重指顺序无关（各表独立）。

-- 2a) dl_relation.src_id（出边端点）
UPDATE dl_relation r
SET src_id = m.keep_id
FROM _dl_entity_merge_map m
WHERE r.src_id = m.old_id;

-- 2b) dl_relation.dst_id（入边端点）
UPDATE dl_relation r
SET dst_id = m.keep_id
FROM _dl_entity_merge_map m
WHERE r.dst_id = m.old_id;

-- 2c) dl_attribute.entity_id
UPDATE dl_attribute a
SET entity_id = m.keep_id
FROM _dl_entity_merge_map m
WHERE a.entity_id = m.old_id;

-- 2d) dl_datapoint.entity_id（软列；NULL / 未解析行不在映射内，自动跳过）
UPDATE dl_datapoint d
SET entity_id = m.keep_id
FROM _dl_entity_merge_map m
WHERE d.entity_id = m.old_id;

-- 2e) dl_event.participant_ids（BIGINT[] 数组）：把数组里每个等于 old_id 的元素替换成 keep_id。
-- 用 LATERAL 展开数组 → 对每个元素查映射（未命中保留原值）→ 重新聚合回数组，去重（同组多个旧 id
-- 折成同一 keep 后可能在一行里重复，array_agg(DISTINCT) 去重）。仅更新「确实含被合并 old_id」的行
-- （EXISTS 子查询过滤，避免全表无谓重写）。数组顺序不语义化（参与者集合），去重不丢信息。
UPDATE dl_event ev
SET participant_ids = sub.new_ids
FROM (
    SELECT
        e.id AS event_id,
        array_agg(DISTINCT COALESCE(m.keep_id, pid.elem)) AS new_ids
    FROM dl_event e
    CROSS JOIN LATERAL unnest(e.participant_ids) AS pid(elem)
    LEFT JOIN _dl_entity_merge_map m ON m.old_id = pid.elem
    WHERE e.participant_ids IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM _dl_entity_merge_map m2
          WHERE m2.old_id = ANY(e.participant_ids)
      )
    GROUP BY e.id
) AS sub
WHERE ev.id = sub.event_id;

-- ════════════════════════════════════════════════════════════════════════════
-- 3) 删除多余实体行（已无证据指向；dl_relation/dl_attribute 的 ON DELETE CASCADE 此时无可级联）
-- ════════════════════════════════════════════════════════════════════════════
-- 重指已完成 ⇒ 没有任何证据外键再指向 old_id 集合 ⇒ 删除安全（级联清不到任何证据行）。
DELETE FROM dl_entity
WHERE id IN (SELECT old_id FROM _dl_entity_merge_map);

-- ════════════════════════════════════════════════════════════════════════════
-- 4) 赋 scope：保留下来的合并组 keep 行 → canonical(project_id=NULL)；其余 → provisional(留 project_id)
-- ════════════════════════════════════════════════════════════════════════════
-- 4a) 合并组的保留行：升为全局 canonical，project_id 置 NULL（不再参与隔离/可见性裁定）。
--     keep_id 集合 = 映射表里出现过的 keep_id（去重）。幂等：二次执行映射空 → 此 UPDATE 命中 0 行，
--     已是 canonical 的行不被改（scope 已为 'canonical'，下面 4b 的 WHERE scope IS NULL 也不会回退它）。
UPDATE dl_entity
SET scope = 'canonical', project_id = NULL
WHERE id IN (SELECT DISTINCT keep_id FROM _dl_entity_merge_map);

-- 4b) 其余所有「尚未定 scope」的行（单项目实体 + 二次执行时已存在的存量行）→ provisional，保留 project_id。
--     只填 scope IS NULL 的行：不覆盖 4a 刚设的 canonical、也不覆盖前次迁移已设值的行（幂等可重放）。
UPDATE dl_entity
SET scope = 'provisional'
WHERE scope IS NULL;

-- 4c) scope 现已全行非空 → 加 NOT NULL + DEFAULT（新插入行若 writer 漏赋 scope，默认 provisional 私有，
--     fail-safe：宁可私有不可误全局共享）。DEFAULT 用裸字面量（与 enums.EntityScope.PROVISIONAL 同值）。
ALTER TABLE dl_entity ALTER COLUMN scope SET DEFAULT 'provisional';
DO $$
BEGIN
    -- 仅当列当前允许 NULL 时才加约束（幂等：二次执行已是 NOT NULL 则跳过，避免重复加约束报错）
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'dl_entity' AND column_name = 'scope' AND is_nullable = 'YES'
    ) THEN
        ALTER TABLE dl_entity ALTER COLUMN scope SET NOT NULL;
    END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5) 索引：全局 canonical 部分唯一索引 + scope 过滤索引 +（旧 project 复合 UNIQUE 改造）
-- ════════════════════════════════════════════════════════════════════════════
-- 5a) 全局唯一：同一 (canonical, etype) 在 canonical 档下只允许一行（部分唯一索引，仅约束 scope='canonical'）。
--     provisional 行不受此约束（多项目可各有同名 provisional，正是隐形标的私有并存的来源）。
CREATE UNIQUE INDEX IF NOT EXISTS uq_dl_entity_canonical_global
    ON dl_entity (canonical, etype)
    WHERE scope = 'canonical';

-- 5b) provisional 行的项目内唯一：同一项目同 (canonical,etype) 仍只允许一行 provisional
--     （保持旧 UNIQUE(project_id,canonical,etype) 在 provisional 子集上的去重语义；writer 的 ON CONFLICT
--      依赖此键做稳定 upsert）。canonical 行 project_id=NULL 不进此索引（被 5a 管）。
CREATE UNIQUE INDEX IF NOT EXISTS uq_dl_entity_provisional_per_project
    ON dl_entity (project_id, canonical, etype)
    WHERE scope = 'provisional';

-- 5c) 旧 UNIQUE(project_id,canonical,etype) 约束：与 5b 的部分唯一索引语义重叠但**更严**
--     （它不分 scope，会禁止「一个项目的 provisional + 同名已晋升 canonical(project_id=NULL)」并存——
--      但 canonical 的 project_id=NULL 不与任何 project_id 行撞，故实际不冲突；保留亦可）。
--     为让身份模型干净（唯一性完全由 5a/5b 两个部分索引表达、project_id 不再做身份键），删除旧约束。
--     幂等：按约束名条件删除（建表自动名 dl_entity_project_id_canonical_etype_key）。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'dl_entity'
          AND constraint_name = 'dl_entity_project_id_canonical_etype_key'
          AND constraint_type = 'UNIQUE'
    ) THEN
        ALTER TABLE dl_entity DROP CONSTRAINT dl_entity_project_id_canonical_etype_key;
    END IF;
END $$;

-- 5d) scope 过滤索引：读路径 scope-gate（Phase2）按 scope 分支，建索引支撑 WHERE scope=... 过滤。
CREATE INDEX IF NOT EXISTS idx_dl_entity_scope ON dl_entity (scope);

-- 旧 idx_dl_entity_etype 是 (project_id, etype) 复合；canonical 行 project_id=NULL 仍可用该索引
-- （NULL 在 btree 可索引），保留不动。

-- ════════════════════════════════════════════════════════════════════════════
-- 6) 清理临时映射表
-- ════════════════════════════════════════════════════════════════════════════
DROP TABLE IF EXISTS _dl_entity_merge_map;

-- ════════════════════════════════════════════════════════════════════════════
-- 验证 SQL（迁移后手动核对；全部应满足）
-- ════════════════════════════════════════════════════════════════════════════
-- V1) scope 列存在且非空、有 canonical/provisional 两档分布：
--     SELECT scope, COUNT(*) FROM dl_entity GROUP BY scope;
--     预期：仅 'canonical' / 'provisional'，无 NULL。
--
-- V2) 全局 canonical 无重复 (canonical,etype)（部分唯一索引生效 ⇒ 此查询应返回 0 行）：
--     SELECT canonical, etype, COUNT(*) AS n FROM dl_entity
--       WHERE scope = 'canonical' GROUP BY canonical, etype HAVING COUNT(*) > 1;
--
-- V3) canonical 行的 project_id 必为 NULL、provisional 行必非 NULL（身份模型不变量 ⇒ 两查询都应返回 0 行）：
--     SELECT COUNT(*) FROM dl_entity WHERE scope = 'canonical'   AND project_id IS NOT NULL;
--     SELECT COUNT(*) FROM dl_entity WHERE scope = 'provisional' AND project_id IS NULL;
--
-- V4) 证据外键无悬空（重指 + 删除后，所有证据指向的实体 id 都仍存在 ⇒ 四查询都应返回 0 行）：
--     -- dl_relation 两端
--     SELECT COUNT(*) FROM dl_relation r LEFT JOIN dl_entity e ON e.id = r.src_id WHERE e.id IS NULL;
--     SELECT COUNT(*) FROM dl_relation r LEFT JOIN dl_entity e ON e.id = r.dst_id WHERE e.id IS NULL;
--     -- dl_attribute（硬 FK，理论恒 0；双保险）
--     SELECT COUNT(*) FROM dl_attribute a LEFT JOIN dl_entity e ON e.id = a.entity_id WHERE e.id IS NULL;
--     -- dl_datapoint（软列；entity_id 非 NULL 的行须能解析，NULL 行不算悬空）
--     SELECT COUNT(*) FROM dl_datapoint d LEFT JOIN dl_entity e ON e.id = d.entity_id
--       WHERE d.entity_id IS NOT NULL AND e.id IS NULL;
--     -- dl_event.participant_ids 数组元素（展开后逐个校验，应返回 0 行）
--     SELECT COUNT(*) FROM (
--       SELECT unnest(participant_ids) AS pid FROM dl_event WHERE participant_ids IS NOT NULL
--     ) x LEFT JOIN dl_entity e ON e.id = x.pid WHERE e.id IS NULL;
--
-- V5) 证据表 project_id 列原样保留（ACL 主墙未被本迁移触碰 ⇒ 四表 project_id 仍 NOT NULL、值不变）：
--     SELECT table_name, is_nullable FROM information_schema.columns
--       WHERE table_name IN ('dl_relation','dl_attribute','dl_event','dl_datapoint')
--         AND column_name = 'project_id';
--     预期：四行均 is_nullable = 'NO'。
--
-- V6) 部分唯一索引存在：
--     SELECT indexname FROM pg_indexes
--       WHERE indexname IN ('uq_dl_entity_canonical_global','uq_dl_entity_provisional_per_project','idx_dl_entity_scope');

-- ══════════════════════════════════════════════════════════════════════════════
-- [28/46] 数据层证据 · 045_dl_datapoint_period.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 045_dl_datapoint_period.sql
-- 数据层 M4-S10 · dl_datapoint 加 period（报告期/口径期间）列 —— 冲突检测期间消歧。
--
-- 背景：冲突检测（queries.conflict_candidates）当前按 (entity, metric) 分组，同实体同指标 ≥2 个不同值
--   即判口径冲突。但「2024 营收（实际）」与「2025E 营收（预测）」是**不同期间**的两个值，并非口径分歧，
--   旧逻辑会误判为冲突。本迁移给 dl_datapoint 加 `period` 列承载报告期/期间标签（如 '2024' / '2025E' /
--   '2024Q3' / 'TTM'），抽取层（datapoints.py）抽取、writer 写入、冲突分组键加上 period：
--     · 同实体 + 同（归一后）指标 + **同 period** 仍 ≥2 个不同值 → 真冲突（口径分歧）；
--     · period 不同 → 不同期间快照，不判冲突。
--
-- ── 与证据层 ACL 主墙的关系（M4-C 不变量）─────────────────────────────────
--   dl_datapoint 的 project_id + visibility 列**一字不动**（仍是 substance 隔离主承重墙，迁移 044 V5 断言
--   四证据表 project_id 仍 NOT NULL）。本迁移只**新增** period 标签列，不触碰任何隔离/可见性列。
--
-- 幂等 + 可重放：ADD COLUMN IF NOT EXISTS（可空，存量行 period=NULL 表「期间未知」，不参与期间消歧分组键
--   的 NULL 行按「同 NULL 期」归并——与旧行为等价：存量未标 period 的同指标多值仍按旧口径判冲突）。

-- ════════════════════════════════════════════════════════════════════════════
-- 1) period 列：报告期 / 期间标签（TEXT，可空；NULL=期间未知）
-- ════════════════════════════════════════════════════════════════════════════
-- 不设 NOT NULL：存量行无期间信息，且抽取层并非每个数据点都能定到期间（很多研报数值无明确期间）。
-- period 是「期间维度」标签，非隔离/可见性列，故无 DEFAULT、无约束——仅参与冲突分组键与展示。
ALTER TABLE dl_datapoint ADD COLUMN IF NOT EXISTS period TEXT;

-- ════════════════════════════════════════════════════════════════════════════
-- 2) 索引：冲突分组按 (project_id, entity, metric, period) 聚合，建复合索引支撑该 GROUP BY / 过滤
-- ════════════════════════════════════════════════════════════════════════════
-- 旧 idx_dl_dp_entity 是 (project_id, entity)；冲突分组现加 metric+period 维度，补一个覆盖该聚合的索引
-- （period 放末列，NULL 在 btree 可索引；不影响仅按 entity 的旧查询走旧索引）。
CREATE INDEX IF NOT EXISTS idx_dl_dp_entity_metric_period
    ON dl_datapoint (project_id, entity, metric, period);

-- ════════════════════════════════════════════════════════════════════════════
-- 验证 SQL（迁移后手动核对）
-- ════════════════════════════════════════════════════════════════════════════
-- V1) period 列存在且可空：
--     SELECT column_name, is_nullable, data_type FROM information_schema.columns
--       WHERE table_name = 'dl_datapoint' AND column_name = 'period';
--     预期：1 行，is_nullable = 'YES'，data_type = 'text'。
--
-- V2) 证据层 ACL 主墙未被触碰（project_id 仍 NOT NULL）：
--     SELECT is_nullable FROM information_schema.columns
--       WHERE table_name = 'dl_datapoint' AND column_name = 'project_id';
--     预期：is_nullable = 'NO'。
--
-- V3) 复合索引存在：
--     SELECT indexname FROM pg_indexes WHERE indexname = 'idx_dl_dp_entity_metric_period';

-- ══════════════════════════════════════════════════════════════════════════════
-- [29/46] 中文检索 · 046_zh_fts_tokens.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 046_zh_fts_tokens.sql
-- 中文全文检索修复:tsv 改由「应用层 jieba 预分词文本」驱动(零 PG 扩展依赖)。
--
-- 背景:003 迁移用 to_tsvector('simple', chunk_text) 维护 tsv,注释承诺
-- "中文可后续切换 zhparser/pg_jieba" 但从未兑现。中文无空格,simple 分词器把
-- 整段中文当一个 token,plainto_tsquery 几乎永不命中 → 混合检索(向量+全文+RRF)
-- 的全文半边对中文事实失效。
--
-- 方案:加 chunk_text_tokens 列(应用层 jieba.cut_for_search 产出、空格分隔),
-- 触发器优先用它喂 to_tsvector('simple', ...) —— simple 对空格分隔文本工作正常。
-- 不装任何 PG 扩展;旧行(tokens 为 NULL)回退用 chunk_text,行为与改前等价,
-- 由 scripts/backfill_zh_fts.py 批量回填后逐步收敛。
--
-- 配套:apps/server/services/zh_tokenizer.py(分词器,写入/查询两侧统一口径)
--      apps/server/services/knowledge_service.py(写入路径带 tokens / 查询预分词)
--      scripts/backfill_zh_fts.py(存量回填)

-- ── 1. 预分词文本列 ───────────────────────────────────────────────
ALTER TABLE knowledge_embeddings
    ADD COLUMN IF NOT EXISTS chunk_text_tokens TEXT;

-- ── 2. 触发器函数:tokens 优先,NULL 回退原文(存量行为不变) ─────────
CREATE OR REPLACE FUNCTION update_knowledge_tsv() RETURNS trigger AS $$
BEGIN
    NEW.tsv := to_tsvector('simple', COALESCE(NEW.chunk_text_tokens, NEW.chunk_text, ''));
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

-- ── 3. 触发器:补挂 chunk_text_tokens 的 UPDATE 触发(回填 UPDATE 时重算 tsv) ──
DROP TRIGGER IF EXISTS trg_knowledge_tsv ON knowledge_embeddings;
CREATE TRIGGER trg_knowledge_tsv
    BEFORE INSERT OR UPDATE OF chunk_text, chunk_text_tokens
    ON knowledge_embeddings
    FOR EACH ROW EXECUTE FUNCTION update_knowledge_tsv();

-- GIN 索引沿用 003 的 idx_knowledge_tsv(tsv 列本身没变),无需重建。
-- 存量 tsv 不在迁移里重算(需要应用层 jieba),由回填脚本逐批 UPDATE 触发重算。

-- ── 验证 ─────────────────────────────────────────────────────────
-- 1) 列存在:
--    SELECT column_name FROM information_schema.columns
--     WHERE table_name='knowledge_embeddings' AND column_name='chunk_text_tokens';
-- 2) 触发器覆盖两列:
--    SELECT action_timing, event_manipulation FROM information_schema.triggers
--     WHERE trigger_name='trg_knowledge_tsv';
-- 3) 行为冒烟(插入带 tokens 的行后):
--    SELECT tsv @@ plainto_tsquery('simple', '脑机 接口') FROM knowledge_embeddings
--     WHERE chunk_text_tokens LIKE '%脑机%' LIMIT 1;  -- 期望 t

-- ══════════════════════════════════════════════════════════════════════════════
-- [30/46] 知识库隔离 · 047_kb_isolation_topics.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 047: 知识库三库隔离与作用域 · 主题轴（定盘方案 M1）
--
-- 背景（docs/data-layer/各层实施解决方案/知识库三库隔离与作用域-定盘方案.md）：
--   全局库（fund_wide 池）是无主题大桶，跨赛道材料混放 → 检索/build 的"作用域"过滤无据可依。
--   D3 定盘：不拆物理库，加主题标签——projects.topic（项目即主题容器）+ files.topics（多值）。
--   铁律：落库归属按源路由（全局/项目/个人），主题标签按触发上下文继承（vendor 取数沉淀时
--   从 origin 项目的 topic 继承；origin 同时记入 provenance，见 sinkers）。
--
-- 幂等：全部 IF NOT EXISTS / 条件 DO 块。

-- ① 项目主题：项目即主题容器（NotebookLM 心智）。NULL = 未设主题（作用域过滤退化为 all）。
ALTER TABLE projects ADD COLUMN IF NOT EXISTS topic VARCHAR(64);

-- ② 文件主题标签：多值 JSONB（一篇研报可属多主题）。NULL/[] = 未分类（作用域过渡期放行）。
--    主题词表后续与投研标签树 domain/chain 合一（定盘 §1-D3），本迁移不加 CHECK。
ALTER TABLE files ADD COLUMN IF NOT EXISTS topics JSONB;

-- ③ 作用域过滤索引：检索/build 按 `topics @> '["X"]'` 收窄，GIN 支撑（jsonb_path_ops 即够 @>）。
CREATE INDEX IF NOT EXISTS idx_files_topics ON files USING gin (topics jsonb_path_ops);

-- 验证（psql 手动执行）：
--   SELECT column_name FROM information_schema.columns WHERE table_name='projects' AND column_name='topic';
--   SELECT column_name FROM information_schema.columns WHERE table_name='files' AND column_name='topics';
--   SELECT indexname FROM pg_indexes WHERE tablename='files' AND indexname='idx_files_topics';

-- ══════════════════════════════════════════════════════════════════════════════
-- [31/46] 自动构建 · 048_vendor_origin_autobuild.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 048: 外部结构化源实体的「区域库」标识 + 取数自动构建（防抖）状态表
--
-- 背景（2026-06-11）：
-- 1. dl_entity 的 canonical 实体有两条进料路——研报抽取(build,带 chunk 证据) 与
--    vendor 结构化映射(鲸准/东财,0-LLM 字段映射,无 chunk 证据)。控制台此前混在一个
--    列表展示,用户无法区分"图谱抽取的实体"与"外部数据源灌的实体"。加 vendor_origin
--    标识列,读路径据此分区展示（区域库）。两路都触达的实体(汇流) vendor_origin 仍为
--    TRUE 且 chunk_ids 非空——按"有研报证据"归图谱区,徽标提示亦有外部数据源。
-- 2. 取数自动构建闭环：vendor 沉淀完成后给 origin 项目记"待构建"印记,datacenter 侧
--    防抖清扫器(默认 10 分钟无新沉淀)自动入队 DATALAYER_BUILD。状态表一项目一行。

-- ── dl_entity.vendor_origin ──────────────────────────────────────
ALTER TABLE dl_entity ADD COLUMN IF NOT EXISTS vendor_origin BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_dl_entity_vendor_origin ON dl_entity(vendor_origin) WHERE vendor_origin;

-- 回填：现存 canonical 且无 chunk 证据的实体全部来自 vendor 结构化映射
-- （build 产物 100% 带 chunk_ids,见 dl_entity 既有数据盘点）。幂等可重跑。
UPDATE dl_entity
SET vendor_origin = TRUE
WHERE scope = 'canonical'
  AND (chunk_ids IS NULL OR chunk_ids = '[]'::jsonb)
  AND vendor_origin = FALSE;

-- ── 取数自动构建防抖状态（server 写印记,datacenter 清扫器消费）────────
CREATE TABLE IF NOT EXISTS dl_auto_build_state (
    project_id     UUID PRIMARY KEY,
    pending        BOOLEAN NOT NULL DEFAULT FALSE,   -- 有新沉淀待构建
    last_ingest_at TIMESTAMPTZ,                      -- 最近一次沉淀时刻（防抖基准）
    last_build_at  TIMESTAMPTZ,                      -- 最近一次自动构建入队时刻
    builds_on      DATE,                             -- 当日计数所属日期（跨日重置）
    builds_count   INT NOT NULL DEFAULT 0            -- 当日自动构建次数（防失控上限）
);

-- 验证:
-- SELECT count(*) FILTER (WHERE vendor_origin) AS vendor_entities, count(*) AS total FROM dl_entity;
-- SELECT * FROM dl_auto_build_state;

-- ══════════════════════════════════════════════════════════════════════════════
-- [32/46] 数据层证据 · 049_evidence_source_attribution.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 049: 证据行来源归因（真增量定盘 M0/删除路径前提）
--
-- dl_relation/dl_attribute 是跨文档聚合行（无 file_id 列），删除某文件时无法精确抹掉其图谱贡献
-- （chunk 随文件级联删除后,chunk_ids→file 的反查链就断了——必须物化）。
-- source_file_ids = 贡献文件 id 数组（text 形 uuid）,构建完成后由 chunk_ids→knowledge_embeddings
-- 反查回填（tasks._attribute_evidence_sources）;治理删文件时据此 独占行删/共享行剔除。
-- dl_event/dl_datapoint 已有单值 file_id,不动。

ALTER TABLE dl_relation  ADD COLUMN IF NOT EXISTS source_file_ids JSONB;
ALTER TABLE dl_attribute ADD COLUMN IF NOT EXISTS source_file_ids JSONB;
CREATE INDEX IF NOT EXISTS idx_dl_relation_src_files  ON dl_relation  USING gin (source_file_ids jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_dl_attribute_src_files ON dl_attribute USING gin (source_file_ids jsonb_path_ops);

-- 验证: SELECT count(*) FILTER (WHERE source_file_ids IS NOT NULL) FROM dl_relation;

-- ══════════════════════════════════════════════════════════════════════════════
-- [33/46] 会话统计 · 050_conversation_metrics_bigint.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 050_conversation_metrics_bigint.sql
-- 会话累计指标 int4 → int8：修复 total_duration_ms 等累计列溢出 int32。
--
-- 背景：conversations.total_duration_ms 原为 INTEGER（int4，上限 2,147,483,647）。
--   线上某会话累计耗时达 2,158,325,366ms（≈25 天）→ asyncpg 在 bind 阶段按 int4 编码
--   抛 OverflowError，导致 Agent→server 的会话 upsert
--   （ConversationService.upsert_conversations）该条失败。同类隐患还有
--   input/output/total/cache_read/cache_creation_tokens —— 累计型、随会话生命周期单调增，
--   cache_read_tokens 涨得最快（每轮重计缓存读），迟早同样破 int4。
--
-- 放宽范围（仅"会跨轮次/跨天累加"的列；计数类 message_count / tool_calls_count /
--   error_count 与单值 first_response_ms 不动，它们天然有界）：
--     conversations             : total_duration_ms / input_tokens / output_tokens /
--                                 total_tokens / cache_read_tokens / cache_creation_tokens
--     conversation_daily_tokens : 同名 6 列（与主表 SUM 口径一致，一并对齐避免类型漂移）
--
-- 不在范围内（保持 int4）：
--   * conversation_messages 的单条消息级 token/duration —— 单轮有界（token ≤ 上下文窗口、
--     duration ≤ 单次时长），是上面 SUM 的安全来源。
--   * audit_logs / vendor_proxy_audit_log 等单次调用级计量（per-call，非累计）。
--
-- ⚠ ORM 必须同步：apps/server/models/project.py 已把上述列改为 BigInteger。
--   SQLAlchemy 按列类型渲染 `$n::INTEGER` 强转 —— **只改 DB 不改 ORM 仍会 int4 编码溢出**，
--   两者必须一起上线。
--
-- ⚠ int4→int8 是整表重写，持表级 ACCESS EXCLUSIVE 锁。conversations 较大时请在 Agent 同步
--   低峰执行（或短暂停 server），避免与在线 upsert 抢锁。
--
-- 幂等：逐列判断 data_type，已是 bigint 则跳过（免重复重写）；表/列不存在自动跳过。
-- 原子：整脚本 BEGIN/COMMIT，任一步失败全回滚。


DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT t.tbl, t.col FROM (VALUES
            ('conversations',             'total_duration_ms'),
            ('conversations',             'input_tokens'),
            ('conversations',             'output_tokens'),
            ('conversations',             'total_tokens'),
            ('conversations',             'cache_read_tokens'),
            ('conversations',             'cache_creation_tokens'),
            ('conversation_daily_tokens', 'total_duration_ms'),
            ('conversation_daily_tokens', 'input_tokens'),
            ('conversation_daily_tokens', 'output_tokens'),
            ('conversation_daily_tokens', 'total_tokens'),
            ('conversation_daily_tokens', 'cache_read_tokens'),
            ('conversation_daily_tokens', 'cache_creation_tokens')
        ) AS t(tbl, col)
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name   = rec.tbl
              AND column_name  = rec.col
              AND data_type    = 'integer'   -- 仅当前还是 int4 才改；已 bigint / 不存在则跳过
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I TYPE BIGINT', rec.tbl, rec.col);
            RAISE NOTICE '已放宽 %.% → BIGINT', rec.tbl, rec.col;
        END IF;
    END LOOP;
END $$;


-- ── 验证 SQL（迁移后手动核对，下列 12 行 data_type 应全为 bigint）──
-- SELECT table_name, column_name, data_type
-- FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name IN ('conversations', 'conversation_daily_tokens')
--   AND column_name IN ('total_duration_ms', 'input_tokens', 'output_tokens',
--                       'total_tokens', 'cache_read_tokens', 'cache_creation_tokens')
-- ORDER BY table_name, column_name;

-- ══════════════════════════════════════════════════════════════════════════════
-- [34/46] 个人数据隔离 · 050_dl_owner_personal.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 050_dl_owner_personal.sql
-- 三层权限架构 Plan 1：给 dl_* 证据/身份层加 owner_id，支撑"个人私有图谱"（visibility=personal）。
-- owner_id NULL = 非个人（项目/全局/canonical），存量行默认 NULL → 行为不变（backward-compat）。
-- 个人图谱行由 Plan 2 的 build/writer 写入 owner_id + visibility=personal；本迁移只加列与索引。

ALTER TABLE dl_entity     ADD COLUMN IF NOT EXISTS owner_id UUID;
ALTER TABLE dl_relation   ADD COLUMN IF NOT EXISTS owner_id UUID;
ALTER TABLE dl_event      ADD COLUMN IF NOT EXISTS owner_id UUID;
ALTER TABLE dl_datapoint  ADD COLUMN IF NOT EXISTS owner_id UUID;
ALTER TABLE dl_attribute  ADD COLUMN IF NOT EXISTS owner_id UUID;

-- 个人图谱命中路径 = (visibility='personal' AND owner_id=? AND project_id=?)。
-- 部分索引只覆盖 personal 行（绝大多数行 owner_id 为 NULL，不进索引，省空间）。
CREATE INDEX IF NOT EXISTS idx_dl_entity_owner     ON dl_entity    (owner_id, project_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dl_relation_owner   ON dl_relation  (owner_id, project_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dl_event_owner      ON dl_event     (owner_id, project_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dl_datapoint_owner  ON dl_datapoint (owner_id, project_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dl_attribute_owner  ON dl_attribute (owner_id, project_id) WHERE owner_id IS NOT NULL;

-- 验证（部署后手测）：
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='dl_relation' AND column_name='owner_id';  -- 应 1 行

-- ══════════════════════════════════════════════════════════════════════════════
-- [35/46] 个人数据隔离 · 051_dl_entity_personal_scope.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 051_dl_entity_personal_scope.sql
-- 三层权限架构 B1（纯隔离）：个人私有实体身份。
-- 个人 build 产的实体 = scope='personal' + owner_id（迁移050已加列）+ visibility='personal'，
-- 是**独立私有节点**（不复用全局 canonical），仅 owner 在本项目可见。
-- 与 canonical/provisional 两套唯一键并列，新增 personal 部分唯一键：同一 owner 在同一项目内
-- 同名同类型实体唯一（owner_id 对 personal 行恒非空，无 NULL-distinct 问题）。
-- dl_entity.scope 无 CHECK 约束（迁移044），'personal' 直接可用，无需改约束。

CREATE UNIQUE INDEX IF NOT EXISTS uq_dl_entity_personal_per_owner
    ON dl_entity (project_id, owner_id, canonical, etype)
    WHERE scope = 'personal';

-- 验证（部署后手测）：
--   SELECT indexname FROM pg_indexes WHERE indexname='uq_dl_entity_personal_per_owner';  -- 应 1 行

-- ══════════════════════════════════════════════════════════════════════════════
-- [36/46] 公司档案 · 052_dl_company_profile.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 052_dl_company_profile.sql
-- 数据中台 · 公司信息层(蓝图 Stage B)—— 结构化「公司档案卡」表 + 别名 GIN 索引(自然键锚定加速)。
--
-- 背景:dl_entity 是身份层(规范名+别名+类型),dl_datapoint 装定量事实(营收/市值,带多源口径冲突),
-- 但**公司基础档案**(全称/法人/注册地/成立年/上市板/简介/注册资本)是稳定的文本字段、datapoint 装不下、
-- 也不该当成"会冲突的指标"。本表给每个公司实体一张**一对一**的结构化档案卡(蓝图"公司信息层")。
--   · 自然键 stock_code / legal_id:跨数据源对齐的稳定键(上市=股票代码,未上市=统一社会信用代码),
--     建索引供"按代码找公司"。多代码公司(A+H / 北交所迁码)的全部代码仍在 dl_entity.aliases。
--   · 多源治理:档案字段稳定、冲突罕见 → 一实体一行,按来源 upsert(非空优先,COALESCE 不被 NULL 覆盖);
--     sources 记贡献来源、raw 留各源原始字段(schema 跟不上时的逃生舱)。真正会冲突的定量指标(营收/利润)
--     仍走 dl_datapoint 的多值口径机制,不进本表。
--
-- 幂等:CREATE TABLE/INDEX IF NOT EXISTS;可任意重放。非破坏:只加表+索引,不动任何既有数据。
-- 锚点:与 dl_entity 同 ON DELETE CASCADE(实体删则档案随删,无悬挂档案)。

CREATE TABLE IF NOT EXISTS dl_company_profile (
    entity_id          BIGINT      PRIMARY KEY REFERENCES dl_entity(id) ON DELETE CASCADE,
    -- ── 自然键(跨源对齐稳定键)──────────────────────────────────
    stock_code         TEXT,            -- 主股票代码(如 002415.SZ);全部代码仍在 dl_entity.aliases
    legal_id           TEXT,            -- 统一社会信用代码 / 工商注册号(未上市公司的对齐键)
    -- ── 身份 ──────────────────────────────────────────────────
    full_name          TEXT,            -- 公司全称(工商注册名)
    short_name         TEXT,            -- 简称(冗余 = dl_entity.canonical,便于卡片直出)
    listing_status     TEXT,            -- 上市状态:listed / unlisted
    exchange           TEXT,            -- 交易所(上交所/深交所/北交所/港交所)
    board              TEXT,            -- 上市板(主板/创业板/科创板/北交所/港股)
    listed_date        TEXT,            -- 上市日期(文本容忍 YYYY / YYYY-MM-DD)
    founded_year       INT,             -- 成立年份
    -- ── 业务 / 地区 ───────────────────────────────────────────
    region             TEXT,            -- 注册地 / 总部(省市)
    industry           TEXT,            -- 行业归类(东财 / 申万)
    main_business      TEXT,            -- 主营业务 / 角色
    description        TEXT,            -- 公司简介
    -- ── 工商 / 规模 ───────────────────────────────────────────
    legal_rep          TEXT,            -- 法定代表人
    registered_capital TEXT,            -- 注册资本(带单位文本)
    employees          INT,             -- 员工数
    website            TEXT,            -- 官网
    -- ── 多源治理 ──────────────────────────────────────────────
    sources            JSONB       NOT NULL DEFAULT '[]',  -- 贡献过本档案的来源 slug 列表(provenance)
    trust_tier         TEXT,            -- 整体信任档(取贡献源里最高)
    raw                JSONB,           -- 各源原始字段留存(schema 跟不上时的逃生舱)
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 自然键索引:按股票代码 / legal_id 找公司(跨源锚定 + 控制台按代码检索)。
CREATE INDEX IF NOT EXISTS idx_dl_company_profile_stock ON dl_company_profile (stock_code);
CREATE INDEX IF NOT EXISTS idx_dl_company_profile_legal ON dl_company_profile (legal_id);

-- dl_entity.aliases GIN 索引:实体锚定按"代码/别名 jsonb 命中"找 canonical 实体(vendor 入库 + 研报抽取
-- 都靠它把提及链到 spine,而非只按精确规范名 → 防名字变体造重复实体)。jsonb_path_ops 体积小、@> 命中快。
CREATE INDEX IF NOT EXISTS idx_dl_entity_aliases_gin ON dl_entity USING gin (aliases jsonb_path_ops);

-- ── 验证 SQL(迁移后手动核对)──
-- SELECT table_name FROM information_schema.tables WHERE table_name = 'dl_company_profile';  -- 应 1 行
-- SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'dl_company_profile';   -- 应 20 列
-- SELECT indexname FROM pg_indexes WHERE indexname IN
--   ('idx_dl_company_profile_stock','idx_dl_company_profile_legal','idx_dl_entity_aliases_gin');  -- 应 3 行

-- ══════════════════════════════════════════════════════════════════════════════
-- [37/46] 产业链治理 · 053_relation_vocab_3axis.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 053_relation_vocab_3axis.sql
-- 产业链 relation 词表统一为「投研图谱三轴」（enums.GraphRelation：隶属/所属赛道/上下游）。
--
-- 背景：早期种子脚本(_seed_chain_sql.py)给**人工策展的全局产业链结构边**写了抽取管道的
-- `belongs_to_sector`（双词表混用），而投研标签树的受控词表是：
--   · 隶属(SUBORDINATE)   —— 节点→父节点，分类层级骨架（级别由它推导）
--   · 所属赛道(MEMBERSHIP) —— 公司→赛道节点，归属打标
--   · 上下游(UPSTREAM_DOWNSTREAM) —— 上游→下游，供应链流向（本次无存量，建链时新增）
-- 本迁移把 canonical 结构边按端点类型重标到三轴：公司(src)→所属赛道，其余节点(src)→隶属。
--
-- 不动抽取管道产出的 `belongs_to_sector`（项目级/provisional，RESEARCH_SCHEMA 词表）——
-- 双词表按设计并存（见 enums.GraphRelation docstring），按 relation 值识别命名空间。
-- 渲染不受影响：chain_graph 后端不按 relation 过滤、前端 HierarchyGraph 把每条边都当子→父。
--
-- 幂等：重跑时 canonical 的 belongs_to_sector 已清零，两条 UPDATE 命中 0 行。

-- 公司(src)→赛道：归属边 → 所属赛道
UPDATE dl_relation r
SET relation = '所属赛道'
FROM dl_entity s
WHERE r.src_id = s.id
  AND r.relation = 'belongs_to_sector'
  AND s.scope = 'canonical'
  AND s.etype = 'company';

-- 节点(src=sector/segment/chain)→父节点：层级边 → 隶属
UPDATE dl_relation r
SET relation = '隶属'
FROM dl_entity s
WHERE r.src_id = s.id
  AND r.relation = 'belongs_to_sector'
  AND s.scope = 'canonical'
  AND s.etype <> 'company';

-- ── 验证 SQL（迁移后手动核对）──
-- SELECT relation, count(*) FROM dl_relation GROUP BY relation ORDER BY count(*) DESC;
--   预期：'所属赛道'≈381（公司→赛道）、'隶属'≈29（节点→父）、canonical 的 'belongs_to_sector'=0。
--   （develops_product/works_at/uses_technology 等抽取关系不动。）

-- ══════════════════════════════════════════════════════════════════════════════
-- [38/46] 产业链治理 · 054_chain_audit_batch1.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 054_chain_audit_batch1.sql
-- 产业链审计 batch1（2026-06-22）：清理「多重归属」噪声 —— 删蹭概念边 + 供应商边改「上下游」。
--
-- 背景：dl_relation 全部 410 条赛道边均来自 _seed_chain_sql.py（chunk_ids 全空，非研报抽取）；
-- 70 家公司「多归属」混了三类：① 真多赛道(留) ② 上下游被错标成「所属赛道」(改) ③ 蹭概念(删)。
-- 本迁移 = batch1 高置信子集：下游整机(机器人本体/服务机器人)的供应商边 + 明显蹭概念边；
-- 模块层(执行器/关节模组、灵巧手)的 49 条属 TIER2（真做模块 vs 供零件需逐家判），另行处理。
--
-- 幂等：DELETE 重跑命中 0 行；UPDATE 只认 relation IN ('所属赛道','隶属')，已改成「上下游」的不再命中。
-- 作用域：仅 canonical 链（端点实体 project_id IS NULL；边落 __VENDOR_KB__ 锚点池 …0003）。


-- ① 删蹭概念边（公司与该赛道无真实业务，纯污染筛选）
DELETE FROM dl_relation r
USING dl_entity s, dl_entity d
WHERE r.src_id = s.id AND r.dst_id = d.id
  AND r.relation IN ('所属赛道', '隶属')
  AND s.project_id IS NULL AND d.project_id IS NULL
  AND (s.canonical, d.canonical) IN (
    ('中兴通讯', '机器人本体'), ('中兴通讯', 'AI芯片/算力'),  -- 通信设备商，整个移出具身链
    ('光启技术', '机器人本体'),                              -- 超材料 → 留「轻量化材料」
    ('金发科技', '机器人本体'),                              -- 改性塑料 → 留「轻量化材料」
    ('贝斯特', '机器人本体'),                                -- 汽车涡轮 → 留「行星滚柱丝杠」
    ('思特威-W', 'AI芯片/算力'),                             -- CIS 图像传感器 → 留「传感器·视觉」
    ('晶晨股份', '传感器·视觉'), ('全志科技', '传感器·视觉'),  -- SoC → 留「AI芯片/算力」
    ('星宸科技', '传感器·视觉'), ('云天励飞-U', '传感器·视觉'), -- 视觉 SoC/NPU → 留「AI芯片/算力」
    ('智微智能', '传感器·视觉'),                             -- 服务器/工控机 → 留「工业应用」
    ('隆盛科技', '灵巧手'),                                  -- EGR/磁材 → 留「减速器」
    ('道氏技术', 'AI芯片/算力')                              -- 锂电材料，AI芯片明显错（触觉边暂留待确认）
  );

-- ② 供应商边：所属赛道 → 上下游（零部件厂供货给整机，不属于整机赛道）
UPDATE dl_relation r
SET relation = '上下游'
FROM dl_entity s, dl_entity d
WHERE r.src_id = s.id AND r.dst_id = d.id
  AND r.relation IN ('所属赛道', '隶属')
  AND s.project_id IS NULL AND d.project_id IS NULL
  AND (s.canonical, d.canonical) IN (
    ('鸣志电器', '机器人本体'), ('拓邦股份', '机器人本体'), ('中大力德', '机器人本体'),
    ('奥比中光', '机器人本体'), ('奥比中光', '服务机器人'), ('拓普集团', '机器人本体'),
    ('柯力传感', '机器人本体'), ('绿的谐波', '机器人本体'), ('双环传动', '机器人本体'),
    ('微光股份', '机器人本体'), ('领益智造', '机器人本体'), ('先导智能', '机器人本体'),
    ('瑞芯微', '机器人本体'), ('蓝思科技', '机器人本体'), ('宁波韵升', '机器人本体'),
    ('宝信软件', '机器人本体'), ('兆威机电', '机器人本体')
  );


-- 验证：
--   SELECT relation, COUNT(*) FROM dl_relation WHERE relation IN ('所属赛道','隶属','上下游') GROUP BY relation;
--   -- 机器人本体 的「所属赛道」入边应只剩真整机厂：新松/埃夫特/埃斯顿/新时达/美的/博实/汇川
--   SELECT s.canonical FROM dl_relation r JOIN dl_entity s ON s.id=r.src_id
--     JOIN dl_entity d ON d.id=r.dst_id AND d.canonical='机器人本体'
--     WHERE r.relation IN ('所属赛道','隶属') AND s.etype='company' ORDER BY 1;
--   -- 中兴通讯 应无任何赛道边（已成孤儿，实体可另行清理）

-- ══════════════════════════════════════════════════════════════════════════════
-- [39/46] 产业链治理 · 055_chain_candidates_17.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 055_chain_candidates_17.sql
-- 把 17 家经"主营词选股 + 人工核验"的真零部件/集成商公司补进 canonical 产业链（2026-06-22）。
--
-- 来源：_screen_companies.py 按主营词选股得 106 provisional 候选 → 审掉 89 家概念噪声
-- （宽词"机器人集成"占 82：ST股/通信/医药/电网/教培/家电等跨行业蹭概念）→ 留 17 家真做该环节的，
-- 升 canonical + 挂「所属赛道」边。89 噪声是 provisional 暂存（从不在 CSV/迁移），已删，无需记录。
--
-- 幂等：实体 ON CONFLICT(canonical,etype) WHERE scope='canonical' DO NOTHING；档案/边同。
-- 端点：实体 project_id IS NULL（canonical）；边落 __VENDOR_KB__ 锚点池 …0003。


-- ① 17 canonical 公司实体（aliases 带股票码，跨源自然键）
INSERT INTO dl_entity (project_id, scope, canonical, etype, mentions, aliases, chunk_ids,
                       visibility, trust_tier, vendor_origin, owner_id, embedding_version)
SELECT NULL, 'canonical', v.name, 'company', 1, jsonb_build_array(v.code), '[]'::jsonb,
       'fund_wide', 'external_verified', FALSE, NULL, 1
FROM (VALUES
  ('思看科技','688583.SH'), ('埃科光电','688610.SH'), ('奥普特','688686.SH'),
  ('蓝海华腾','300484.SZ'), ('星辰科技','920885.BJ'),
  ('华中数控','300161.SZ'), ('乐创技术','920425.BJ'),
  ('瑞松科技','688090.SH'), ('科大智能','300222.SZ'), ('中科微至','688211.SH'),
  ('今天国际','300532.SZ'), ('东杰智能','300486.SZ'), ('华昌达','300278.SZ'),
  ('江苏北人','688218.SH'), ('克来机电','603960.SH'), ('天永智能','603895.SH'),
  ('泰禾智能','603656.SH')
) AS v(name, code)
ON CONFLICT (canonical, etype) WHERE scope='canonical' DO NOTHING;

-- ② 档案卡（股票码 + 申万行业）
INSERT INTO dl_company_profile (entity_id, stock_code, industry, sources, trust_tier)
SELECT e.id, v.code, v.ind, '["em_select:curated"]'::jsonb, 'external_verified'
FROM (VALUES
  ('思看科技','688583.SH','机械设备-通用设备-仪器仪表'),
  ('埃科光电','688610.SH','机械设备-通用设备-仪器仪表'),
  ('奥普特','688686.SH','机械设备-自动化设备-其他自动化设备'),
  ('蓝海华腾','300484.SZ','机械设备-自动化设备-工控设备'),
  ('星辰科技','920885.BJ','机械设备-自动化设备-工控设备'),
  ('华中数控','300161.SZ','机械设备-通用设备-机床工具'),
  ('乐创技术','920425.BJ','机械设备-自动化设备-工控设备'),
  ('瑞松科技','688090.SH','机械设备-自动化设备-机器人'),
  ('科大智能','300222.SZ','电力设备-电网设备-电网自动化设备'),
  ('中科微至','688211.SH','机械设备-专用设备-其他专用设备'),
  ('今天国际','300532.SZ','计算机-IT服务Ⅱ-IT服务Ⅲ'),
  ('东杰智能','300486.SZ','机械设备-自动化设备-其他自动化设备'),
  ('华昌达','300278.SZ','机械设备-自动化设备-工控设备'),
  ('江苏北人','688218.SH','机械设备-自动化设备-机器人'),
  ('克来机电','603960.SH','机械设备-自动化设备-其他自动化设备'),
  ('天永智能','603895.SH','机械设备-专用设备-其他专用设备'),
  ('泰禾智能','603656.SH','机械设备-专用设备-其他专用设备')
) AS v(name, code, ind)
JOIN dl_entity e ON e.canonical=v.name AND e.etype='company' AND e.scope='canonical'
ON CONFLICT (entity_id) DO NOTHING;

-- ③ 「所属赛道」边（公司 → 赛道节点）
INSERT INTO dl_relation (project_id, src_id, relation, dst_id, weight, chunk_ids, visibility, trust_tier, owner_id)
SELECT CAST('00000000-0000-0000-0000-000000000003' AS uuid), s.id, '所属赛道', d.id, 1,
       '[]'::jsonb, 'fund_wide', 'external_verified', NULL
FROM (VALUES
  ('思看科技','传感器·视觉'), ('埃科光电','传感器·视觉'), ('奥普特','传感器·视觉'),
  ('蓝海华腾','电机/驱动·伺服系统'), ('星辰科技','电机/驱动·伺服系统'),
  ('华中数控','控制器'), ('乐创技术','控制器'),
  ('瑞松科技','系统集成'), ('科大智能','系统集成'), ('中科微至','系统集成'),
  ('今天国际','系统集成'), ('东杰智能','系统集成'), ('华昌达','系统集成'),
  ('江苏北人','系统集成'), ('克来机电','系统集成'), ('天永智能','系统集成'),
  ('泰禾智能','系统集成')
) AS m(comp, sector)
JOIN dl_entity s ON s.canonical=m.comp AND s.etype='company' AND s.scope='canonical'
JOIN dl_entity d ON d.canonical=m.sector AND d.project_id IS NULL
ON CONFLICT (project_id, src_id, relation, dst_id) DO NOTHING;


-- 验证：
--   SELECT count(*) FROM dl_entity WHERE scope='canonical' AND etype='company';  -- +17
--   SELECT s.canonical, d.canonical FROM dl_relation r
--     JOIN dl_entity s ON s.id=r.src_id JOIN dl_entity d ON d.id=r.dst_id
--     WHERE s.canonical IN ('思看科技','瑞松科技','华中数控') AND r.relation='所属赛道';

-- ══════════════════════════════════════════════════════════════════════════════
-- [40/46] 产业链治理 · 056_chain_audit_batch2.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 056_chain_audit_batch2.sql
-- 产业链审计 batch2(2026-06-23):清「机器人本体」的单挂边概念股 + 供应商边改「上下游」。
-- 承接 054(多归属 batch1)。仅动上市公司的错挂边;未上市机器人创业公司(listing_status=unlisted,
-- 智元/优必选等)是有意挂在机器人本体的,不在本次名单、自动保留。
-- 幂等:DELETE 重跑命中 0;UPDATE 只认 relation IN ('所属赛道','隶属'),已改的不再命中。


-- ① 删概念股(与机器人无真实业务:锂钴矿/整车/军工/光缆/存储/重型等)
DELETE FROM dl_relation r
USING dl_entity s, dl_entity d
WHERE r.src_id = s.id AND r.dst_id = d.id
  AND r.relation IN ('所属赛道', '隶属')
  AND s.project_id IS NULL AND d.canonical = '机器人本体'
  AND s.canonical IN (
    '中航成飞', '电科蓝天', '三瑞智能',                       -- 军工(非机器人)
    '中矿资源', '华友钴业', '天齐锂业', '永兴材料', '赣锋锂业', -- 锂钴矿
    '广汽集团', '赛力斯', '长安汽车',                          -- 整车
    '亨通光电', '长飞光纤', '万马股份', '远东股份',            -- 光缆/线缆
    '佰维存储', '江海股份', '立昂微',                          -- 存储/电容/硅片
    '亿纬锂能', '科达利',                                      -- 电池/电池结构件
    '中联重科', '上海电气', '鸿路钢构', '上纬新材', '东阳光', '协创数据'  -- 工程机械/电气/钢构/材料/综合/数据
  );

-- ② 供应商边改上下游(真给机器人供货,但不是整机厂)
UPDATE dl_relation r
SET relation = '上下游'
FROM dl_entity s, dl_entity d
WHERE r.src_id = s.id AND r.dst_id = d.id
  AND r.relation IN ('所属赛道', '隶属')
  AND s.project_id IS NULL AND d.canonical = '机器人本体'
  AND s.canonical IN (
    '三花智控', '万向钱潮', '银轮股份', '恒立液压',            -- 汽零/热管理/液压
    '立讯精密', '长盈精密', '鹏鼎控股', '东山精密', '胜宏科技', '本川智能',  -- 结构件/PCB
    '卧龙电驱', '江特电机', '金力永磁',                        -- 电机/磁材
    '兆易创新', '思瑞浦', '扬杰科技', '水晶光电',              -- 芯片/光学
    '华勤技术', '中控技术',                                    -- ODM/系统集成
    '海天精工', '科德数控', '纽威数控', '宇环数控', '华辰装备'  -- 机床母机(装备供应)
  );


-- 验证:机器人本体 的「所属赛道」入边应只剩真整机厂(埃夫特/埃斯顿/新松/新时达/拓斯达/博实/巨轮/凯尔达/汇川/美的/科大讯飞)
--   + 未上市创业公司(智元/优必选等);概念股清零,供应商转为「上下游」。

-- ══════════════════════════════════════════════════════════════════════════════
-- [41/46] 产业链治理 · 057_curation_log.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 057_curation_log.sql
-- 策展审计链(2026-06-23):全局骨架"人工审核并入"工作流的可回溯账本。
-- 每一次 promote(升为新 canonical)/ merge(并入已有 canonical 作别名)/ reject(驳回) 都记一行:
--   谁(actor)、何时(created_at)、对哪个候选(candidate_*)、做了什么(action)、归到哪(target_*)、为什么(reason)。
-- 这条"理由+可回溯"正是把【精准维护】和【自动堆积】区分开的关键 —— 骨架成员资格永远人工、留痕。
-- 同时充当审核队列去重:已 action 过的候选不再回到 /curation/candidates。
-- 幂等:IF NOT EXISTS。

CREATE TABLE IF NOT EXISTS dl_curation_log (
    id                  BIGSERIAL PRIMARY KEY,
    action              TEXT NOT NULL,        -- 'promote' | 'merge' | 'reject'
    candidate_canonical TEXT NOT NULL,        -- 候选(provisional)的 canonical 名
    candidate_etype     TEXT NOT NULL,        -- 候选类型(v1 仅 company)
    candidate_entity_id BIGINT,               -- 候选 dl_entity id(merge/reject-drop 后该行可能已删)
    source_project_id   UUID,                 -- 候选原属项目(provisional 暂存处)
    target_sector       TEXT,                 -- promote:归入的赛道节点(belongs_to_sector / 所属赛道)
    target_canonical    TEXT,                 -- merge:并入的已有 canonical 名
    relation            TEXT,                 -- promote:归位关系类型(默认 所属赛道)
    reason              TEXT,                  -- 决策理由(策展审计核心)
    actor_id            UUID,                  -- 操作者 user id
    actor_name          TEXT,                  -- 操作者用户名(冗余,便于直读账本)
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 审核队列去重:按 (canonical, etype) 快速判断某候选是否已被处理过。
CREATE INDEX IF NOT EXISTS idx_dl_curation_log_candidate
    ON dl_curation_log (candidate_canonical, candidate_etype);
-- 按时间倒序看账本。
CREATE INDEX IF NOT EXISTS idx_dl_curation_log_created ON dl_curation_log (created_at DESC);

-- 验证:
--   SELECT action, count(*) FROM dl_curation_log GROUP BY 1;
--   SELECT * FROM dl_curation_log ORDER BY created_at DESC LIMIT 20;

-- ══════════════════════════════════════════════════════════════════════════════
-- [42/46] 认证安全 · 058_user_token_version.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 058: users.token_version —— 改密即时失效在途 access token(审计 #7 剩余缺口)
-- access token 签发时把当前 token_version 写进 tv 声明;改密时自增。
-- get_current_user 比对 payload.tv 与库中 token_version,不符即拒(30 分钟窗口清零)。
-- 默认 0 + token 端 tv 默认 0 → 未改密用户的旧 token 仍有效,滚动升级零中断。
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version INTEGER NOT NULL DEFAULT 0;

-- 验证:
--   SELECT column_name, data_type, column_default FROM information_schema.columns
--   WHERE table_name='users' AND column_name='token_version';

-- ══════════════════════════════════════════════════════════════════════════════
-- [43/46] 客户端诊断 · 059_agent_diagnostics.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 059: agent_diagnostics —— 客户端 opt-in 诊断上报接收表(仅匿名元数据)。
-- 隐私:不存对话内容/文件路径/查询词/PII。install_id 匿名,user_id 可空。
CREATE TABLE IF NOT EXISTS agent_diagnostics (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    install_id   VARCHAR(64)  NOT NULL,
    user_id      UUID,
    app_version  VARCHAR(32)  NOT NULL,
    event        VARCHAR(128) NOT NULL,
    level        VARCHAR(16)  NOT NULL,
    exc_type     VARCHAR(128),
    code         VARCHAR(64),
    occurred_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_diagnostics_install ON agent_diagnostics(install_id);
CREATE INDEX IF NOT EXISTS idx_agent_diagnostics_event ON agent_diagnostics(event);
CREATE INDEX IF NOT EXISTS idx_agent_diagnostics_created ON agent_diagnostics(created_at DESC);

-- 验证:SELECT event, exc_type, count(*) FROM agent_diagnostics GROUP BY 1,2 ORDER BY 3 DESC;

-- ══════════════════════════════════════════════════════════════════════════════
-- [44/46] 客户端发布 · 060_agent_release_canary.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 060: 客户端版本灰度发布
--
-- 目标:
--   - 新上传版本默认仅灰度测试账号可见，验证后再切到 public 全量发布
--   - 既有线上版本保持 public，部署迁移不会让普通用户失去当前更新源
--   - 灰度名单按 release 独立保存，演示网/公网/内网的数据库天然隔离
--
-- canary_user_ids 保存 UUID 字符串 JSON 数组。选择 JSONB 而非额外关联表，是因为
-- 名单随版本固化、规模极小且只在 manifest/download 两条读路径做包含判断。


ALTER TABLE agent_release
    ADD COLUMN IF NOT EXISTS rollout_stage VARCHAR(16);

ALTER TABLE agent_release
    ADD COLUMN IF NOT EXISTS canary_user_ids JSONB;

-- 历史版本上传时系统还没有灰度语义，必须视为已经全量发布。
UPDATE agent_release
SET rollout_stage = 'public'
WHERE rollout_stage IS NULL;

UPDATE agent_release
SET canary_user_ids = '[]'::jsonb
WHERE canary_user_ids IS NULL;

ALTER TABLE agent_release
    ALTER COLUMN rollout_stage SET DEFAULT 'canary',
    ALTER COLUMN rollout_stage SET NOT NULL,
    ALTER COLUMN canary_user_ids SET DEFAULT '[]'::jsonb,
    ALTER COLUMN canary_user_ids SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ck_agent_release_rollout_stage'
    ) THEN
        ALTER TABLE agent_release
            ADD CONSTRAINT ck_agent_release_rollout_stage
            CHECK (rollout_stage IN ('canary', 'public'));
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS ix_agent_release_layer_stage_active_created
    ON agent_release (layer, rollout_stage, is_active, created_at DESC);

CREATE INDEX IF NOT EXISTS ix_agent_release_canary_users
    ON agent_release USING GIN (canary_user_ids);


-- 验证:
--   SELECT layer, version, rollout_stage, canary_user_ids
--   FROM agent_release ORDER BY created_at DESC;

-- ══════════════════════════════════════════════════════════════════════════════
-- [45/46] 系统空间清理 · 062_remove_system_personal_space.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 062: 清理内部 SYSTEM 账号的空个人空间
--
-- 背景:
--   020 的存量补建曾为所有 users 创建默认项目，内部 __system__ 数据归属账号
--   也因此得到一个「个人空间」。super_admin 查看全量业务项目时会看到它。
--
-- 安全策略:
--   - 仅处理 role='system' 且 is_default=TRUE 的项目；
--   - 系统空间中有明确 user_id 的会话先迁回该用户自己的个人空间，消息等子表
--     通过 conversation_id 关联，无需逐表改写；
--   - 动态检查当前 schema 中所有 project_id 引用，存在任何业务数据就保留；
--   - project_members 只允许系统 owner 自己的一条成员记录，删除项目时由 FK 级联清理；
--   - 可重复执行，无目标记录时不产生变化。


-- 旧版本会让 super_admin 在工作区选中系统个人空间，期间创建的会话实际仍带有
-- 当前登录用户的 user_id。按该字段迁回用户自己的默认项目，避免清理时丢失对话。
UPDATE conversations AS conversation
SET project_id = personal_project.id,
    updated_at = now()
FROM projects AS system_project
JOIN users AS system_owner ON system_owner.id = system_project.owner_id
JOIN projects AS personal_project ON personal_project.is_default = TRUE
WHERE conversation.project_id = system_project.id
  AND system_project.is_default = TRUE
  AND system_owner.role = 'system'
  AND conversation.user_id IS NOT NULL
  AND personal_project.owner_id = conversation.user_id
  AND personal_project.id <> system_project.id;

DO $$
DECLARE
    target RECORD;
    reference_column RECORD;
    has_business_data BOOLEAN;
    has_reference BOOLEAN;
BEGIN
    FOR target IN
        SELECT p.id, p.owner_id
        FROM projects p
        JOIN users u ON u.id = p.owner_id
        WHERE p.is_default = TRUE
          AND u.role = 'system'
    LOOP
        has_business_data := FALSE;

        -- 不硬编码业务表名：后续新增带 project_id 的表也会自动纳入保护范围。
        FOR reference_column IN
            SELECT table_schema, table_name, column_name
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND column_name = 'project_id'
              AND table_name NOT IN ('projects', 'project_members')
        LOOP
            EXECUTE format(
                'SELECT EXISTS (SELECT 1 FROM %I.%I WHERE %I = $1)',
                reference_column.table_schema,
                reference_column.table_name,
                reference_column.column_name
            )
            INTO has_reference
            USING target.id;

            IF has_reference THEN
                has_business_data := TRUE;
                EXIT;
            END IF;
        END LOOP;

        IF NOT has_business_data
           AND NOT EXISTS (
               SELECT 1
               FROM project_members m
               WHERE m.project_id = target.id
                 AND (m.user_id <> target.owner_id OR m.role <> 'owner')
           )
        THEN
            DELETE FROM projects WHERE id = target.id;
        END IF;
    END LOOP;
END
$$;


-- 验证：应返回 0 行；如系统空间含业务数据则会保留，需人工迁移后再清理。
-- SELECT p.id, u.username
-- FROM projects p JOIN users u ON u.id = p.owner_id
-- WHERE p.is_default = TRUE AND u.role = 'system';

-- ══════════════════════════════════════════════════════════════════════════════
-- [46/46] 模型网关 · 063_llm_gateway_config.sql
-- ══════════════════════════════════════════════════════════════════════════════

-- 063: 客户端统一 LLM 网关目录。
--
-- 这里只保存非敏感配置；真实 API Key 由管理后台写入 vendor_credentials vault，
-- 使用 (vendor_slug='llm-gateway', env_name='LLM_GATEWAY_KEY') 定位。

INSERT INTO system_config (id, key, value, description, category)
VALUES (
    gen_random_uuid(),
    'llm_gateway',
    '{
      "enabled": false,
      "upstream_url": "",
      "upstream_protocol": "anthropic",
      "default_model": "deepseek-v4-pro",
      "models": [
        {"id":"deepseek-v4-pro","display_name":"DeepSeek V4 Pro","context_window_tokens":1000000,"reasoning":true},
        {"id":"deepseek-v4-flash","display_name":"DeepSeek V4 Flash","context_window_tokens":1000000,"reasoning":false},
        {"id":"kimi-k2.6","display_name":"Kimi K2.6","context_window_tokens":200000,"reasoning":false},
        {"id":"glm-5.1","display_name":"GLM-5.1","context_window_tokens":200000,"reasoning":true},
        {"id":"qwen3.7-plus","display_name":"通义千问 3.7 Plus","context_window_tokens":200000,"reasoning":false},
        {"id":"MiniMax-M2.5","display_name":"MiniMax M2.5","context_window_tokens":200000,"reasoning":false}
      ]
    }'::jsonb,
    '客户端统一模型网关目录（真实 Key 存加密 vault）',
    'general'
)
ON CONFLICT (key) DO NOTHING;

-- 验证：
-- SELECT key, value - 'api_key' FROM system_config WHERE key = 'llm_gateway';
-- SELECT vendor_slug, env_name, status FROM vendor_credentials WHERE vendor_slug = 'llm-gateway';

-- 提交前强校验：任何终态对象缺失都会抛错，使整个事务回滚。
DO $$
DECLARE
    missing_objects TEXT;
BEGIN
    SELECT string_agg(required.object_name, ', ' ORDER BY required.object_name)
    INTO missing_objects
    FROM (
        VALUES
            ('table conversation_messages', to_regclass('public.conversation_messages') IS NOT NULL),
            ('table conversation_daily_tokens', to_regclass('public.conversation_daily_tokens') IS NOT NULL),
            ('table agent_release', to_regclass('public.agent_release') IS NOT NULL),
            ('table vendor_credentials', to_regclass('public.vendor_credentials') IS NOT NULL),
            ('table vendor_definitions', to_regclass('public.vendor_definitions') IS NOT NULL),
            ('table vendor_call_log', to_regclass('public.vendor_call_log') IS NOT NULL),
            ('table dl_entity', to_regclass('public.dl_entity') IS NOT NULL),
            ('table dl_relation', to_regclass('public.dl_relation') IS NOT NULL),
            ('table dl_company_profile', to_regclass('public.dl_company_profile') IS NOT NULL),
            ('table dl_curation_log', to_regclass('public.dl_curation_log') IS NOT NULL),
            ('table agent_diagnostics', to_regclass('public.agent_diagnostics') IS NOT NULL),
            ('column users.token_version', EXISTS (
                SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='token_version'
            )),
            ('column projects.category', EXISTS (
                SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='projects' AND column_name='category'
            )),
            ('column projects.topic', EXISTS (
                SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='projects' AND column_name='topic'
            )),
            ('column agent_release.rollout_stage', EXISTS (
                SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='agent_release' AND column_name='rollout_stage'
            )),
            ('column knowledge_embeddings.chunk_text_tokens', EXISTS (
                SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='knowledge_embeddings' AND column_name='chunk_text_tokens'
            )),
            ('column dl_entity.scope', EXISTS (
                SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='dl_entity' AND column_name='scope'
            )),
            ('config llm_gateway', EXISTS (SELECT 1 FROM system_config WHERE key='llm_gateway'))
    ) AS required(object_name, present)
    WHERE NOT required.present;

    IF missing_objects IS NOT NULL THEN
        RAISE EXCEPTION '020 → 063 迁移终态校验失败，缺少：%', missing_objects;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='conversations' AND column_name='messages'
    ) THEN
        RAISE EXCEPTION '旧 conversations.messages 列仍存在，拒绝提交';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name IN ('conversations', 'conversation_daily_tokens')
          AND column_name IN ('total_duration_ms', 'input_tokens', 'output_tokens',
                              'total_tokens', 'cache_read_tokens', 'cache_creation_tokens')
          AND data_type <> 'bigint'
    ) THEN
        RAISE EXCEPTION '会话累计指标仍有非 BIGINT 列，拒绝提交';
    END IF;
END
$$;

COMMIT;

-- 提交后只读摘要：应返回一行，status=ok。
SELECT
    'ok' AS status,
    current_database() AS database_name,
    (SELECT count(*) FROM information_schema.tables WHERE table_schema='public') AS public_table_count,
    (SELECT count(*) FROM system_config WHERE key IN (
        'release_max_size_mb', 'skill_packaging', 'data_layer', 'llm_gateway'
    )) AS required_config_count;
