import DictationCore
import Foundation
import GRDB

/// The app's SQLite database. One writer; a file database is a WAL `DatabasePool`.
public final class AppDatabase: Sendable {
  let writer: any DatabaseWriter

  init(_ writer: any DatabaseWriter) throws {
    self.writer = writer
    try Self.migrator.migrate(writer)
  }

  public static func open(at url: URL) throws -> AppDatabase {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try AppDatabase(DatabasePool(path: url.path))
  }

  /// Opens the database at `url`. When only `formerURL` exists, moves it to `url` first with its
  /// WAL and shared-memory files, so a renamed file keeps the user's history.
  public static func open(at url: URL, formerlyAt formerURL: URL) throws -> AppDatabase {
    try moveFile(from: formerURL, to: url)
    return try open(at: url)
  }

  /// Moves the main file last, so a move cut short repeats on the next launch.
  static func moveFile(from formerURL: URL, to url: URL) throws {
    let files = FileManager.default
    guard files.fileExists(atPath: formerURL.path), !files.fileExists(atPath: url.path) else { return }
    for suffix in ["-wal", "-shm", ""] {
      let source = URL(filePath: formerURL.path + suffix)
      let target = URL(filePath: url.path + suffix)
      guard files.fileExists(atPath: source.path) else { continue }
      if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
      try files.moveItem(at: source, to: target)
    }
  }

  /// Closes the connections; later reads and writes throw. Safe to call more than once.
  public func close() throws {
    try writer.close()
  }

  static func inMemory() throws -> AppDatabase {
    try AppDatabase(DatabaseQueue())
  }

  /// Migrations are named, ordered and append-only. A shipped migration is never edited: add a
  /// new one, and commit its snapshot (scripts/storage/record-snapshot.sh) so the build proves it.
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(
        sql: """
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at INTEGER NOT NULL,
            recording_ms INTEGER NOT NULL,
            mode TEXT NOT NULL,
            target_app_name TEXT,
            target_bundle_id TEXT
          );
          CREATE INDEX sessions_started_at ON sessions(started_at);
          CREATE INDEX sessions_target_bundle_id ON sessions(target_bundle_id);
          CREATE TABLE transcripts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            created_at INTEGER NOT NULL,
            text TEXT NOT NULL,
            language TEXT
          );
          CREATE INDEX transcripts_session_id ON transcripts(session_id);
          CREATE INDEX transcripts_created_at_id ON transcripts(created_at, id);
          CREATE TABLE session_metrics (
            session_id INTEGER PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
            word_count INTEGER NOT NULL,
            effective_ms INTEGER NOT NULL,
            computed_at INTEGER NOT NULL
          );
          CREATE TABLE shortcut_bindings (
            action TEXT PRIMARY KEY,
            key_code INTEGER NOT NULL,
            modifiers INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(key_code, modifiers)
          );
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          );
          """)
    }
    // Preferences live in UserDefaults so they load when the database fails to open.
    migrator.registerMigration("v2") { db in
      try db.execute(sql: "DROP TABLE settings")
    }
    return migrator
  }

  /// Saves the session, its transcript and its metrics in one transaction.
  public func save(_ entry: DictationEntry, savedAt: Date = .now, hostNow: HostTime = .now()) async throws {
    let savedMs = unixMilliseconds(savedAt)
    let startedMs = savedMs - Int64(hostNow.milliseconds(since: entry.pressedAt).rounded())
    let recordingMs = milliseconds(entry.recordingDuration)
    let text = entry.transcript.text
    try await writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (started_at, recording_ms, mode, target_app_name, target_bundle_id)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          startedMs, recordingMs, entry.mode.storedName, entry.target?.name, entry.target?.bundleIdentifier,
        ])
      let sessionID = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO transcripts (session_id, created_at, text) VALUES (?, ?, ?)",
        arguments: [sessionID, savedMs, text])
      // Parakeet reports no transcript duration, so effective time falls back to recording time.
      try db.execute(
        sql:
          "INSERT INTO session_metrics (session_id, word_count, effective_ms, computed_at) VALUES (?, ?, ?, ?)",
        arguments: [sessionID, wordCount(text), recordingMs, savedMs])
    }
  }

  public func transcriptPage(limit: Int) async throws -> TranscriptPage {
    try await writer.read { try Self.fetchPage($0, limit: limit) }
  }

  /// Emits the newest `limit` transcripts as previews, again after every change. The
  /// Transcripts screen grows `limit` to load more.
  public func transcripts(limit: Int) -> some AsyncSequence<TranscriptPage, any Error> {
    ValueObservation.tracking { try Self.fetchPage($0, limit: limit) }.values(in: writer)
  }

  /// The distinct bundle ids dictated into, at most `limit`, so their app icons can be resolved
  /// before a screen shows them. Reads the bundle id index, not the sessions.
  public func appBundleIDs(limit: Int = 64) async throws -> [String] {
    try await writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT target_bundle_id FROM sessions
          WHERE target_bundle_id IS NOT NULL ORDER BY target_bundle_id LIMIT ?
          """,
        arguments: [limit])
    }
  }

  /// One transcript with its full text, or nil when it no longer exists.
  public func transcript(id: TranscriptItem.ID) async throws -> TranscriptDetail? {
    try await writer.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT t.id, t.created_at, t.text, s.recording_ms, s.target_app_name, s.target_bundle_id,
            s.mode, m.word_count, m.effective_ms
          FROM transcripts t JOIN sessions s ON s.id = t.session_id
          LEFT JOIN session_metrics m ON m.session_id = t.session_id
          WHERE t.id = ?
          """,
        arguments: [id]
      ).map { row in
        let text: String = row[2]
        let effectiveMs: Int64? = row[8]
        return TranscriptDetail(
          id: row[0], createdAt: date(unixMilliseconds: row[1]), text: text,
          recordingDuration: .milliseconds(row[3] as Int64), appName: row[4], bundleID: row[5],
          mode: RecordingMode(storedName: row[6]), words: row[7] ?? wordCount(text),
          effectiveDuration: effectiveMs.map { .milliseconds($0) })
      }
    }
  }

  /// Deletes one transcript's session in one transaction, so the cascade removes the transcript
  /// and its metrics with it. Returns false when it no longer exists.
  @discardableResult
  public func deleteTranscript(id: TranscriptItem.ID) async throws -> Bool {
    try await writer.write { db in
      try db.execute(
        sql: "DELETE FROM sessions WHERE id = (SELECT session_id FROM transcripts WHERE id = ?)",
        arguments: [id])
      return db.changesCount > 0
    }
  }

  /// The list shows two lines of each transcript, so it reads a prefix, never the full text,
  /// and one row past the page to learn whether more exist without counting every row.
  private static func fetchPage(_ db: Database, limit: Int) throws -> TranscriptPage {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT t.id, t.created_at, substr(t.text, 1, ?), s.recording_ms, s.target_app_name, s.target_bundle_id,
          length(t.text) > ?
        FROM transcripts t JOIN sessions s ON s.id = t.session_id
        ORDER BY t.created_at DESC, t.id DESC
        LIMIT ?
        """,
      arguments: [TranscriptItem.previewLength, TranscriptItem.previewLength, limit + 1])
    let items = rows.prefix(limit).map { row in
      TranscriptItem(
        id: row[0],
        createdAt: date(unixMilliseconds: row[1]),
        preview: row[2],
        recordingDuration: .milliseconds(row[3] as Int64),
        appName: row[4],
        bundleID: row[5],
        isTruncated: row[6])
    }
    return TranscriptPage(items: items, hasMore: rows.count > limit)
  }
}

extension RecordingMode {
  var storedName: String {
    switch self {
    case .toggle: "toggle"
    case .pushToTalk: "pushToTalk"
    }
  }

  init?(storedName: String) {
    switch storedName {
    case "toggle": self = .toggle
    case "pushToTalk": self = .pushToTalk
    default: return nil
    }
  }
}

func date(unixMilliseconds: Int64) -> Date {
  Date(timeIntervalSince1970: Double(unixMilliseconds) / 1000)
}

func unixMilliseconds(_ date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 * 1000).rounded())
}

func milliseconds(_ duration: Duration) -> Int64 {
  let (seconds, attoseconds) = duration.components
  return seconds * 1000 + attoseconds / 1_000_000_000_000_000
}

/// Counts words as the number of `\S+` runs.
func wordCount(_ text: String) -> Int {
  text.split(whereSeparator: \.isWhitespace).count
}
