import Foundation
import GRDB
import Testing

@testable import DictationCore
@testable import Storage

private struct Snapshot: CustomTestStringConvertible, Sendable {
  let name: String
  let url: URL
  var testDescription: String { name }
}

private func snapshots() -> [Snapshot] {
  guard
    let folder = Bundle.module.url(forResource: "Snapshots", withExtension: nil),
    let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  else { return [] }
  return urls.filter { $0.pathExtension == "sql" }
    .map { Snapshot(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private func load(_ snapshot: Snapshot) throws -> DatabaseQueue {
  let queue = try DatabaseQueue()
  // GRDB opens databases in defensive mode, which refuses the dump's writable_schema lines. The
  // AUTOINCREMENT tables already create sqlite_sequence, so dropping them changes nothing.
  let sql = try String(contentsOf: snapshot.url, encoding: .utf8)
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter {
      !$0.hasPrefix("PRAGMA writable_schema") && !$0.hasPrefix("CREATE TABLE IF NOT EXISTS sqlite_sequence")
    }
    .joined(separator: "\n")
  try queue.writeWithoutTransaction { db in
    do {
      try db.execute(sql: sql)
    } catch {
      if db.isInsideTransaction { try db.rollback() }
      throw error
    }
    try db.execute(sql: "PRAGMA foreign_keys = ON")
  }
  return queue
}

private func schema(_ reader: any DatabaseReader) throws -> [[String?]] {
  try reader.read { db in
    try Row.fetchAll(
      db,
      sql: """
        SELECT type, name, tbl_name, sql FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name
        """
    ).map { [$0[0], $0[1], $0[2], $0[3]] }
  }
}

private let recordPath = ProcessInfo.processInfo.environment["STORAGE_RECORD_SNAPSHOT"]

struct SnapshotMigrationTests {
  /// A shipped migration is frozen by its snapshot, so each one has exactly one. An unshipped one
  /// has none while its schema still changes.
  @Test func everyShippedMigrationHasASnapshot() {
    let shipped = AppDatabase.migrator.migrations.filter { !$0.hasPrefix(DatabaseMigrator.unshippedPrefix) }
    #expect(!shipped.isEmpty)
    #expect(snapshots().map(\.name) == shipped)
  }

  /// Release registers only the shipped migrations. A shipped one after an unshipped one would run
  /// after it in Debug and without it in Release.
  @Test func unshippedMigrationsComeLast() {
    let migrations = AppDatabase.migrator.migrations
    let firstUnshipped =
      migrations.firstIndex { $0.hasPrefix(DatabaseMigrator.unshippedPrefix) } ?? migrations.endIndex
    #expect(migrations[firstUnshipped...].allSatisfy { $0.hasPrefix(DatabaseMigrator.unshippedPrefix) })
  }

  @Test(arguments: snapshots())
  fileprivate func rowsSurviveMigration(_ snapshot: Snapshot) throws {
    let queue = try load(snapshot)
    try AppDatabase.migrator.migrate(queue)
    func value<T: DatabaseValueConvertible>(_ sql: String, as: T.Type = T.self) throws -> T? {
      try queue.read { try T.fetchOne($0, sql: sql) }
    }
    for table in ["sessions", "transcripts", "session_metrics"] {
      #expect(try value("SELECT COUNT(*) FROM \(table)", as: Int.self) == 2)
    }
    #expect(try value("SELECT COUNT(*) FROM shortcut_bindings", as: Int.self) == 2)
    #expect(
      try value("SELECT text FROM transcripts WHERE session_id = 2", as: String.self)
        == "Zażółć gęślą jaźń\nsecond line")
    #expect(
      try value("SELECT target_bundle_id FROM sessions WHERE id = 1", as: String.self) == "com.apple.Notes")
    #expect(
      try value("SELECT COUNT(*) FROM sessions WHERE id = 2 AND target_app_name IS NULL", as: Int.self) == 1)
    #expect(try value("SELECT word_count FROM session_metrics WHERE session_id = 2", as: Int.self) == 5)
    #expect(try value("SELECT key_code FROM shortcut_bindings WHERE action = 'toggle'", as: Int.self) == 40)
    #expect(try queue.read { try !$0.tableExists("settings") })
  }

  @Test(arguments: snapshots())
  fileprivate func shippedMigrationIsUnchanged(_ snapshot: Snapshot) throws {
    let fresh = try DatabaseQueue()
    try AppDatabase.migrator.migrate(fresh, upTo: snapshot.name)
    #expect(try schema(fresh) == schema(load(snapshot)))
  }

  @Test(.enabled(if: recordPath != nil, "Set STORAGE_RECORD_SNAPSHOT to record a snapshot"))
  func recordSnapshot() async throws {
    let url = URL(filePath: try #require(recordPath))
    try? FileManager.default.removeItem(at: url)
    let database = try AppDatabase.open(at: url)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let now = HostTime(ticks: 1_000_000_000)
    try await database.save(
      try entry("Hello from Notes", pressedAt: now.advanced(by: .seconds(-3))), savedAt: base, hostNow: now)
    try await database.save(
      try entry("Zażółć gęślą jaźń\nsecond line", session: 2, mode: .pushToTalk, pressedAt: now, target: nil),
      savedAt: base.addingTimeInterval(60), hostNow: now)
    try await database.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO shortcut_bindings (action, key_code, modifiers, updated_at) VALUES
            ('toggle', 40, 5, 1700000000000), ('cancel', 53, 0, 1700000000000);
          """)
    }
    _ = try await database.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
  }
}
