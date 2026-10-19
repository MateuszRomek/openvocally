PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
INSERT INTO grdb_migrations VALUES('v1');
INSERT INTO grdb_migrations VALUES('v2');
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at INTEGER NOT NULL,
  recording_ms INTEGER NOT NULL,
  mode TEXT NOT NULL,
  target_app_name TEXT,
  target_bundle_id TEXT
);
INSERT INTO sessions VALUES(1,1699999997000,2000,'toggle','Notes','com.apple.Notes');
INSERT INTO sessions VALUES(2,1700000060000,2000,'pushToTalk',NULL,NULL);
CREATE TABLE transcripts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  text TEXT NOT NULL,
  language TEXT
);
INSERT INTO transcripts VALUES(1,1,1700000000000,'Hello from Notes',NULL);
INSERT INTO transcripts VALUES(2,2,1700000060000,unistr('Zażółć gęślą jaźń\u000asecond line'),NULL);
CREATE TABLE session_metrics (
  session_id INTEGER PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  word_count INTEGER NOT NULL,
  effective_ms INTEGER NOT NULL,
  computed_at INTEGER NOT NULL
);
INSERT INTO session_metrics VALUES(1,3,2000,1700000000000);
INSERT INTO session_metrics VALUES(2,5,2000,1700000060000);
CREATE TABLE shortcut_bindings (
  action TEXT PRIMARY KEY,
  key_code INTEGER NOT NULL,
  modifiers INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(key_code, modifiers)
);
INSERT INTO shortcut_bindings VALUES('toggle',40,5,1700000000000);
INSERT INTO shortcut_bindings VALUES('cancel',53,0,1700000000000);
PRAGMA writable_schema=ON;
CREATE TABLE IF NOT EXISTS sqlite_sequence(name,seq);
DELETE FROM sqlite_sequence;
INSERT INTO sqlite_sequence VALUES('sessions',2);
INSERT INTO sqlite_sequence VALUES('transcripts',2);
CREATE INDEX sessions_started_at ON sessions(started_at);
CREATE INDEX sessions_target_bundle_id ON sessions(target_bundle_id);
CREATE INDEX transcripts_session_id ON transcripts(session_id);
CREATE INDEX transcripts_created_at_id ON transcripts(created_at, id);
PRAGMA writable_schema=OFF;
COMMIT;
