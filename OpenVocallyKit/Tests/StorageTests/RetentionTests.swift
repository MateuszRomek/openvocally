import Foundation
import GRDB
import Testing

@testable import DictationCore
@testable import Storage

struct RetentionTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test(arguments: [
    (TranscriptRetention.days7, 1_699_395_200.0),
    (.days30, 1_697_408_000.0),
    (.days90, 1_692_224_000.0),
  ])
  func cutoffSubtractsWholeDays(retention: TranscriptRetention, expected: Double) {
    #expect(retention.cutoff(now: now) == Date(timeIntervalSince1970: expected))
  }

  @Test func neverHasNoCutoff() {
    #expect(TranscriptRetention.never.cutoff(now: now) == nil)
  }

  @Test func deletesOnlySessionsOlderThanTheCutoff() async throws {
    let database = try AppDatabase.inMemory()
    try await saveAged(database, days: [40, 31, 29, 1])
    let deleted = try await database.deleteTranscripts(
      olderThan: try #require(TranscriptRetention.days30.cutoff(now: now)))
    #expect(deleted == 2)
    #expect(try counts(database) == [2, 2, 2])
    #expect(try await database.transcriptCount() == 2)
  }

  @Test func deleteAllEmptiesHistoryAndKeepsShortcuts() async throws {
    let database = try AppDatabase.inMemory()
    try await saveAged(database, days: [3, 2, 1])
    try await database.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO shortcut_bindings (action, key_code, modifiers, updated_at)
          VALUES ('toggle', 1, 2, 0)
          """)
    }
    #expect(try await database.deleteAllTranscripts() == 3)
    #expect(try counts(database) == [0, 0, 0])
    let kept = try await database.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shortcut_bindings")
    }
    #expect(kept == 1)
  }

  private func saveAged(_ database: AppDatabase, days: [Double]) async throws {
    let pressedAt = HostTime.now()
    for age in days {
      try await database.save(
        try entry("hello", pressedAt: pressedAt), savedAt: now.addingTimeInterval(-age * 86_400),
        hostNow: pressedAt)
    }
  }

  private func counts(_ database: AppDatabase) throws -> [Int] {
    try database.writer.read { db in
      try ["sessions", "transcripts", "session_metrics"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
      }
    }
  }

  @Test func hasTranscriptsFollowsSavesAndDeleteAll() async throws {
    let database = try AppDatabase.inMemory()
    var states = database.hasTranscripts().makeAsyncIterator()
    #expect(try await states.next(isolation: #isolation) == false)
    try await database.save(try entry("one"))
    #expect(try await states.next(isolation: #isolation) == true)
    try await database.deleteAllTranscripts()
    #expect(try await states.next(isolation: #isolation) == false)
  }
}
