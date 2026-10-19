#if DEBUG
  import Foundation
  import GRDB
  import Testing

  @testable import Storage

  struct SeedTranscriptsTests {
    @Test func seedsEveryTableOnceWithTheNewestAtNow() async throws {
      let database = try AppDatabase.inMemory()
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      try await database.seedTranscripts(count: 12_000, now: now)
      try await database.seedTranscripts(count: 500, now: now)

      let counts = try await database.writer.read { db in
        try ["sessions", "transcripts", "session_metrics"].map {
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
        }
      }
      #expect(counts == [12_000, 12_000, 12_000])

      let page = try await database.transcriptPage(limit: 30)
      #expect(page.items.count == 30)
      #expect(page.hasMore)
      let newest = try #require(page.items.first)
      #expect(newest.createdAt <= now)
      #expect(now.timeIntervalSince(newest.createdAt) < 3_600 * 24)

      let mismatched = try await database.writer.read {
        try Int.fetchOne(
          $0,
          sql: """
            SELECT COUNT(*) FROM transcripts t JOIN session_metrics m ON m.session_id = t.session_id
            WHERE m.word_count < 3 OR m.word_count > 5000
            """)
      }
      #expect(mismatched == 0)
      let longest = try await database.writer.read {
        try Int.fetchOne($0, sql: "SELECT MAX(word_count) FROM session_metrics")
      }
      #expect((longest ?? 0) > 1_500)
    }
  }
#endif
