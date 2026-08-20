BEGIN IMMEDIATE;
CREATE TABLE schema_meta(version INTEGER NOT NULL);
INSERT INTO schema_meta(version) VALUES (1);
CREATE TABLE users(
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_phc TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('admin','operator')),
  can_transmit INTEGER NOT NULL CHECK(can_transmit IN (0,1)),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  must_change_password INTEGER NOT NULL CHECK(must_change_password IN (0,1)),
  auth_revision INTEGER NOT NULL DEFAULT 1 CHECK(auth_revision >= 1),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_login_at INTEGER,
  deleted_at INTEGER
);
CREATE TABLE browser_sessions(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
  secret_digest BLOB NOT NULL UNIQUE,
  created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
  idle_expires_at INTEGER NOT NULL, absolute_expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE TABLE devices(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL, platform TEXT NOT NULL CHECK(platform = 'ios'),
  created_at INTEGER NOT NULL, last_seen_at INTEGER, revoked_at INTEGER
);
CREATE TABLE access_credentials(
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
  secret_digest BLOB NOT NULL UNIQUE, created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, revoked_at INTEGER
);
CREATE TABLE refresh_credentials(
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
  family_id TEXT NOT NULL, secret_digest BLOB NOT NULL UNIQUE,
  previous_id TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  used_at INTEGER, revoked_at INTEGER
);
CREATE TABLE login_throttles(
  scope_key TEXT PRIMARY KEY, failure_count INTEGER NOT NULL,
  window_started_at INTEGER NOT NULL, blocked_until INTEGER NOT NULL
);
CREATE TABLE audit_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
  action TEXT NOT NULL, result TEXT NOT NULL,
  actor_user_id TEXT, actor_device_id TEXT, actor_session_id TEXT,
  target_id TEXT, source_address TEXT, metadata_json TEXT NOT NULL
);
COMMIT;
