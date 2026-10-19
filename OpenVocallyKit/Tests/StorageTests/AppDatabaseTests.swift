import Foundation
import GRDB
import Testing

@testable import DictationCore
@testable import Storage

struct AppDatabaseTests {
  @Test func foreignKeysAreOn() throws {
    let database = try AppDatabase.inMemory()
    let on = try database.writer.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
    #expect(on == true)
  }

  @Test func fileDatabaseUsesWAL() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = try AppDatabase.open(at: folder.appending(path: "nested/app.sqlite"))
    let mode = try database.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
    #expect(mode == "wal")
  }

  @Test func openMovesTheFormerFile() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let former = folder.appending(path: "former.sqlite")
    let current = folder.appending(path: "current.sqlite")
    let original = try AppDatabase.open(at: former)
    try original.writer.write { try $0.execute(sql: "CREATE TABLE marker (x INTEGER)") }
    try original.close()

    let database = try AppDatabase.open(at: current, formerlyAt: former)
    #expect(try database.writer.read { try $0.tableExists("marker") })
    #expect(!FileManager.default.fileExists(atPath: former.path))
  }

  @Test func openKeepsBothFilesWhenTheNewOneExists() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let former = folder.appending(path: "former.sqlite")
    let current = folder.appending(path: "current.sqlite")
    let original = try AppDatabase.open(at: former)
    try original.writer.write { try $0.execute(sql: "CREATE TABLE marker (x INTEGER)") }
    try original.close()
    try AppDatabase.open(at: current).close()

    let database = try AppDatabase.open(at: current, formerlyAt: former)
    #expect(try !database.writer.read { try $0.tableExists("marker") })
    #expect(FileManager.default.fileExists(atPath: former.path))
  }

  @Test func saveWritesSessionTranscriptAndMetrics() async throws {
    let database = try AppDatabase.inMemory()
    let pressedAt = HostTime.now()
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try await database.save(
      entry("  hello  wide\nworld ", mode: .pushToTalk, pressedAt: pressedAt, recording: .milliseconds(1500)),
      savedAt: savedAt, hostNow: pressedAt.advanced(by: .seconds(3)))
    let row = try #require(
      try read(database) {
        try Row.fetchOne(
          $0,
          sql: """
            SELECT s.started_at, s.recording_ms, s.mode, s.target_app_name, s.target_bundle_id,
              t.created_at, t.text, m.word_count, m.effective_ms, m.computed_at
            FROM sessions s JOIN transcripts t ON t.session_id = s.id JOIN session_metrics m ON m.session_id = s.id
            """)
      })
    #expect(row[0] as Int64 == 1_699_999_997_000)
    #expect(row[1] as Int64 == 1500)
    #expect(row[2] as String == "pushToTalk")
    #expect(row[3] as String? == "Notes")
    #expect(row[4] as String? == "com.apple.Notes")
    #expect(row[5] as Int64 == 1_700_000_000_000)
    #expect(row[6] as String == "hello  wide\nworld")
    #expect(row[7] as Int == 3)
    #expect(row[8] as Int64 == 1500)
    #expect(row[9] as Int64 == 1_700_000_000_000)
  }

  @Test func failedMetricsInsertRollsBackTheSession() async throws {
    let database = try AppDatabase.inMemory()
    try write(database) {
      try $0.execute(
        sql:
          "CREATE TRIGGER fail_metrics BEFORE INSERT ON session_metrics BEGIN SELECT RAISE(ABORT, 'boom'); END"
      )
    }
    await #expect(throws: DatabaseError.self) { try await database.save(try entry("lost")) }
    let counts = try read(database) { db in
      try ["sessions", "transcripts", "session_metrics"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
      }
    }
    #expect(counts == [0, 0, 0])
  }

  @Test func pageIsNewestFirstLimitedAndKnowsWhetherMoreExist() async throws {
    let database = try AppDatabase.inMemory()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    try await database.save(try entry("first"), savedAt: base)
    try await database.save(try entry("second", target: nil), savedAt: base.addingTimeInterval(60))
    try await database.save(try entry("tie"), savedAt: base.addingTimeInterval(60))
    let page = try await database.transcriptPage(limit: 2)
    #expect(page.hasMore)
    #expect(page.items.map(\.preview) == ["tie", "second"])
    #expect(try await database.transcriptPage(limit: 3).hasMore == false)
    #expect(page.items[1].appName == nil)
    #expect(page.items[1].createdAt == base.addingTimeInterval(60))
    #expect(page.items[1].recordingDuration == .seconds(2))
    #expect(page.items[0].bundleID == "com.apple.Notes")
  }

  @Test func observationEmitsAfterSave() async throws {
    let database = try AppDatabase.inMemory()
    var iterator = database.transcripts(limit: 10).makeAsyncIterator()
    let initial = try await iterator.next(isolation: #isolation)
    #expect(initial?.items.isEmpty == true)
    #expect(initial?.hasMore == false)
    try await database.save(try entry("live"))
    let next = try await iterator.next(isolation: #isolation)
    #expect(next?.items.map(\.preview) == ["live"])
  }

  @Test func longTextIsTruncatedWithAnEllipsisAndShortTextIsNot() async throws {
    let database = try AppDatabase.inMemory()
    let long = String(repeating: "a", count: 299) + "👍🏽 tail"
    try await database.save(try entry("short text"))
    try await database.save(try entry(long))
    let items = try await database.transcriptPage(limit: 2).items
    let longItem = try #require(items.first { $0.isTruncated })
    #expect(longItem.preview == String(repeating: "a", count: 299))
    #expect(longItem.displayPreview == String(repeating: "a", count: 299) + "…")
    let shortItem = try #require(items.first { !$0.isTruncated })
    #expect(shortItem.preview == "short text")
    #expect(shortItem.displayPreview == "short text")
  }

  @Test func pageHoldsAPreviewAndTheDetailHoldsTheWholeText() async throws {
    let database = try AppDatabase.inMemory()
    let text = (0..<200).map { "wörd\($0)" }.joined(separator: " ")
    try await database.save(try entry(text, recording: .seconds(65)))
    let item = try #require(try await database.transcriptPage(limit: 1).items.first)
    #expect(item.preview == String(text.prefix(TranscriptItem.previewLength - 1)))
    #expect(item.isTruncated)

    let detail = try #require(try await database.transcript(id: item.id))
    #expect(detail.text == text)
    #expect(detail.words == 200)
    #expect(detail.recordingDuration == .seconds(65))
    #expect(detail.appName == "Notes")
    #expect(detail.mode == .toggle)
    #expect(detail.effectiveDuration == .seconds(65))
    let pace = try #require(detail.wordsPerMinute)
    #expect(abs(pace - 200 / (65.0 / 60)) < 0.001)
    #expect(detail.createdAt == item.createdAt)
    #expect(try await database.transcript(id: item.id + 1) == nil)
  }

  @Test func deletingOneTranscriptRemovesItsSessionTranscriptAndMetricsOnly() async throws {
    let database = try AppDatabase.inMemory()
    for text in ["keep one", "delete me", "keep two"] { try await database.save(try entry(text)) }
    let page = try await database.transcriptPage(limit: 3)
    let doomed = try #require(page.items.first { $0.preview == "delete me" })

    #expect(try await database.deleteTranscript(id: doomed.id))
    let counts = try read(database) { db in
      try ["sessions", "transcripts", "session_metrics"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
      }
    }
    #expect(counts == [2, 2, 2])
    #expect(try await database.transcriptPage(limit: 3).items.map(\.preview) == ["keep two", "keep one"])
    #expect(try await database.deleteTranscript(id: doomed.id) == false)
  }

  @Test func appBundleIDsAreDistinctAndSkipUnknownApps() async throws {
    let database = try AppDatabase.inMemory()
    try await database.save(try entry("one"))
    try await database.save(try entry("two", session: 2))
    try await database.save(
      try entry("three", session: 3, target: TargetApp(name: "Mail", bundleIdentifier: "com.apple.mail")))
    try await database.save(
      try entry("four", session: 4, target: TargetApp(name: "Unknown", bundleIdentifier: nil)))
    #expect(try await database.appBundleIDs() == ["com.apple.Notes", "com.apple.mail"])
    #expect(try await database.appBundleIDs(limit: 1).count == 1)
  }

  @Test func daysGroupInOrder() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let dayStart = Date(timeIntervalSince1970: 1_700_006_400)
    func item(_ id: Int64, _ offset: TimeInterval) -> TranscriptItem {
      TranscriptItem(
        id: id, createdAt: dayStart.addingTimeInterval(offset), preview: "t\(id)", recordingDuration: .zero,
        appName: nil, bundleID: nil)
    }
    let items = [item(3, 90_000), item(2, 3600), item(1, 60)]
    let days = TranscriptDay.group(items, calendar: calendar)
    #expect(days.map(\.id) == [dayStart.addingTimeInterval(86_400), dayStart])
    #expect(days.map { $0.items.map(\.id) } == [[3], [2, 1]])
    #expect(TranscriptDay.group([], calendar: calendar).isEmpty)
  }
}

/// GRDB's synchronous access. In an async test the compiler would pick the async overloads,
/// which need Sendable results such as Row is not.
private func read<T>(_ database: AppDatabase, _ body: (Database) throws -> T) throws -> T {
  try database.writer.read(body)
}

private func write(_ database: AppDatabase, _ body: (Database) throws -> Void) throws {
  try database.writer.write(body)
}

struct AppDatabaseCloseTests {
  @Test func `closing twice is fine and a later read throws`() throws {
    let database = try AppDatabase.inMemory()
    try database.close()
    try database.close()
    #expect(throws: (any Error).self) {
      try database.writer.read { try Int.fetchOne($0, sql: "SELECT 1") }
    }
  }
}
