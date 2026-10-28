/** 用独立的内存 PostgreSQL 引擎执行交付 SQL，验证交接、引用保留、幂等和回滚。 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

// 仅剥离 psql 的客户端指令，所有数据库 SQL 原样执行。
const migration = readFileSync(new URL('../server_upgrade_074_to_075.sql', import.meta.url), 'utf8')
  .replace(/^\\set ON_ERROR_STOP on\r?\n/, '');
const secondAdminMigration = readFileSync(new URL('../server_upgrade_075_to_076.sql', import.meta.url), 'utf8')
  .replace(/^\\set ON_ERROR_STOP on\r?\n/, '');

async function fixture() {
  const db = new PGlite();
  await db.exec(`
    CREATE TABLE users (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), username varchar(64) UNIQUE NOT NULL,
      email varchar(255) UNIQUE NOT NULL, password_hash text NOT NULL DEFAULT '',
      auth_source varchar(32) NOT NULL, role varchar(32) NOT NULL,
      status varchar(32) NOT NULL DEFAULT 'active', iama_user_id varchar(128) UNIQUE,
      token_version integer NOT NULL DEFAULT 0, must_change_password boolean NOT NULL DEFAULT true,
      failed_login_attempts integer NOT NULL DEFAULT 0, failed_login_window_start timestamptz,
      locked_until timestamptz, iama_access_token text, updated_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE TABLE audit_logs (
      id uuid PRIMARY KEY, user_id uuid REFERENCES users(id), action varchar(64) NOT NULL,
      resource_type varchar(64), resource_id text, detail jsonb, created_at timestamptz DEFAULT now()
    );
    CREATE TABLE projects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES users(id));
    INSERT INTO users (username,email,auth_source,role,password_hash,iama_user_id) VALUES
      ('super_admin','old@example.invalid','local','super_admin','synthetic-hash',NULL),
      ('local-operator','operator@example.invalid','local','admin','synthetic-hash',NULL),
      ('01069355','liupw@haier.com','iama','admin','', 'iama-target'),
      ('sso-other','other@example.invalid','iama','user','legacy-hash','iama-other'),
      ('system-owner','system@example.invalid','local','system','',NULL);
    INSERT INTO projects (owner_id) SELECT id FROM users WHERE username = 'super_admin';
    INSERT INTO audit_logs (id,user_id,action) SELECT gen_random_uuid(), id, 'HISTORICAL_EVENT'
      FROM users WHERE username = 'super_admin';
  `);
  return db;
}

async function snapshot(db) {
  return {
    users: (await db.query('SELECT * FROM users ORDER BY username')).rows,
    projects: (await db.query('SELECT * FROM projects ORDER BY id')).rows,
    audit: (await db.query('SELECT * FROM audit_logs ORDER BY id')).rows,
  };
}

test('提升指定 SSO 管理员，退役本地账号，保留业务与审计关联，重跑不产生额外变更', async () => {
  const db = await fixture();
  try {
    const before = await snapshot(db);
    await db.exec(migration);
    const after = await snapshot(db);
    assert.equal(after.users.length, before.users.length);
    assert.deepEqual(after.projects, before.projects);
    assert.deepEqual(after.audit.find((row) => row.action === 'HISTORICAL_EVENT'), before.audit[0]);
    const target = after.users.find((row) => row.username === '01069355');
    assert.equal(target.id, before.users.find((row) => row.username === '01069355').id);
    assert.equal(target.role, 'super_admin');
    assert.equal(target.status, 'active');
    assert.equal(target.token_version, 1);
    for (const row of after.users.filter((row) => row.auth_source === 'local' && row.role !== 'system')) {
      assert.equal(row.status, 'disabled');
      assert.equal(row.password_hash, '');
      assert.equal(row.role, 'user');
      assert.equal(row.token_version, 1);
    }
    const other = after.users.find((row) => row.username === 'sso-other');
    assert.equal(other.role, 'user');
    assert.equal(other.status, 'active');
    assert.equal(other.password_hash, '');
    assert.equal(other.token_version, 0);
    assert.deepEqual(after.users.find((row) => row.role === 'system'), before.users.find((row) => row.role === 'system'));
    assert.equal(after.audit.filter((row) => row.action === 'LOCAL_AUTH_RETIRED').length, 2);
    assert.equal(after.audit.filter((row) => row.action === 'SSO_ADMIN_PROMOTED').length, 1);
    await db.exec(migration);
    assert.deepEqual(await snapshot(db), after);
  } finally { await db.close(); }
});

for (const [name, change] of [
  ['目标不存在', "DELETE FROM users WHERE username='01069355'"],
  ['目标不是 SSO', "UPDATE users SET auth_source='local' WHERE username='01069355'"],
  ['目标已停用', "UPDATE users SET status='disabled' WHERE username='01069355'"],
  ['目标没有绑定 ID', "UPDATE users SET iama_user_id=NULL WHERE username='01069355'"],
  ['邮箱不匹配', "UPDATE users SET email='wrong@example.invalid' WHERE username='01069355'"],
]) {
  test(`${name}时整笔中止，旧管理员保持可用`, async () => {
    const db = await fixture();
    try {
      await db.exec(change);
      const before = await snapshot(db);
      await assert.rejects(db.exec(migration), /SSO 管理员切换中止/);
      await db.exec('ROLLBACK');
      assert.deepEqual(await snapshot(db), before);
    } finally { await db.close(); }
  });
}

test('中途审计写入失败时，已执行的提权及停用一起回滚', async () => {
  const db = await fixture();
  try {
    await db.exec("ALTER TABLE audit_logs ADD CONSTRAINT fail_retirement CHECK (action <> 'LOCAL_AUTH_RETIRED')");
    const before = await snapshot(db);
    await assert.rejects(db.exec(migration));
    await db.exec('ROLLBACK');
    assert.deepEqual(await snapshot(db), before);
  } finally { await db.close(); }
});

/** 075 后已有一个可用超级管理员，第二个账号保持实际截图中的管理员身份。 */
async function secondAdminFixture() {
  const db = await fixture();
  await db.exec(migration);
  await db.exec(`INSERT INTO users (username,email,auth_source,role,iama_user_id,must_change_password)
    VALUES ('A1016659','A1016659@haier.com','iama','admin','iama-second',false)`);
  return db;
}

test('076 增加第二位超级管理员，保留第一位及其他数据，撤销目标旧会话且可重跑', async () => {
  const db = await secondAdminFixture();
  try {
    const before = await snapshot(db);
    await db.exec(secondAdminMigration);
    const after = await snapshot(db);
    const target = after.users.find((row) => row.username === 'A1016659');
    const previous = before.users.find((row) => row.username === 'A1016659');
    assert.equal(target.id, previous.id);
    assert.equal(target.role, 'super_admin');
    assert.equal(target.status, 'active');
    assert.equal(target.token_version, previous.token_version + 1);
    assert.equal(after.users.filter((row) => row.role === 'super_admin' && row.status === 'active').length, 2);
    assert.deepEqual(after.users.filter((row) => row.id !== target.id), before.users.filter((row) => row.id !== target.id));
    assert.deepEqual(after.projects, before.projects);
    assert.deepEqual(after.audit.filter((row) => row.detail?.migration !== '076'), before.audit);
    assert.equal(after.audit.filter((row) => row.detail?.migration === '076').length, 1);
    await db.exec(secondAdminMigration);
    assert.deepEqual(await snapshot(db), after);
  } finally { await db.close(); }
});

for (const [name, change] of [
  ['第一位管理员未就绪', "UPDATE users SET role='admin' WHERE username='01069355'"],
  ['第二位用户不存在', "DELETE FROM users WHERE username='A1016659'"],
  ['第二位邮箱不匹配', "UPDATE users SET email='wrong@example.invalid' WHERE username='A1016659'"],
  ['第二位不是 SSO', "UPDATE users SET auth_source='local' WHERE username='A1016659'"],
  ['第二位已停用', "UPDATE users SET status='disabled' WHERE username='A1016659'"],
  ['第二位绑定为空', "UPDATE users SET iama_user_id=' ' WHERE username='A1016659'"],
  ['第二位为系统占位账号', "UPDATE users SET role='system' WHERE username='A1016659'"],
  ['审计写入失败', "ALTER TABLE audit_logs ADD CONSTRAINT fail_second_admin CHECK (detail->>'migration' <> '076')"],
]) {
  test(`076 ${name}时回滚，第一位管理员及全部历史数据不变`, async () => {
    const db = await secondAdminFixture();
    try {
      await db.exec(change);
      const before = await snapshot(db);
      await assert.rejects(db.exec(secondAdminMigration));
      await db.exec('ROLLBACK');
      assert.deepEqual(await snapshot(db), before);
    } finally { await db.close(); }
  });
}
