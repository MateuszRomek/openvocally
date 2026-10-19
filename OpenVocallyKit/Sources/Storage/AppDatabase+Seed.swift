#if DEBUG
  import Foundation
  import GRDB

  extension AppDatabase {
    /// Deletes the sessions saved for the target app `name`, with their transcripts and metrics,
    /// so a measurement that saved synthetic dictations leaves its seed as it found it. Returns
    /// the transcripts left.
    @discardableResult
    public func deleteSessions(targetAppName name: String) async throws -> Int {
      try await writer.write { db in
        try db.execute(sql: "DELETE FROM sessions WHERE target_app_name = ?", arguments: [name])
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts") ?? 0
      }
    }

    /// Measurement data for `make transcripts-latency`. Fills an empty database with `count`
    /// synthetic dictations through the real schema, newest at `now`, spread over about two years.
    /// The texts are deterministic: most are short, with a tail up to about 5,000 words. Does
    /// nothing when the database already has transcripts.
    public func seedTranscripts(count: Int, now: Date = .now) async throws {
      let existing = try await writer.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcripts") ?? 0
      }
      guard existing == 0, count > 0 else { return }
      let nowMs = unixMilliseconds(now)
      let spanMs: Int64 = 2 * 365 * 24 * 3_600_000
      let stepMs = spanMs / Int64(count)
      var generator = SeedGenerator(seed: 77)
      let batchSize = 5_000
      for batchStart in stride(from: 0, to: count, by: batchSize) {
        var rows: [SeedRow] = []
        rows.reserveCapacity(batchSize)
        for index in batchStart..<min(batchStart + batchSize, count) {
          let age = Int64(count - 1 - index) * stepMs
          rows.append(
            generator.row(createdAt: nowMs - age - Int64(generator.next(below: UInt64(stepMs / 2 + 1)))))
        }
        try await writer.write { [rows] db in
          let session = try db.makeStatement(
            sql: """
              INSERT INTO sessions (started_at, recording_ms, mode, target_app_name, target_bundle_id)
              VALUES (?, ?, ?, ?, ?)
              """)
          let transcript = try db.makeStatement(
            sql: "INSERT INTO transcripts (session_id, created_at, text) VALUES (?, ?, ?)")
          let metrics = try db.makeStatement(
            sql:
              "INSERT INTO session_metrics (session_id, word_count, effective_ms, computed_at) VALUES (?, ?, ?, ?)"
          )
          for row in rows {
            try session.execute(arguments: [
              row.createdAt - row.recordingMs, row.recordingMs, row.mode, row.app.name, row.app.bundleID,
            ])
            let sessionID = db.lastInsertedRowID
            try transcript.execute(arguments: [sessionID, row.createdAt, row.text])
            try metrics.execute(arguments: [sessionID, row.words, row.recordingMs, row.createdAt])
          }
        }
      }
    }
  }

  private struct SeedRow {
    let createdAt: Int64
    let recordingMs: Int64
    let mode: String
    let app: (name: String, bundleID: String)
    let text: String
    let words: Int
  }

  /// SplitMix64, so every seeded database holds the same texts.
  private struct SeedGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

    mutating func next(below bound: UInt64) -> UInt64 {
      next() % max(bound, 1)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
      range.lowerBound + Int(next(below: UInt64(range.count)))
    }

    /// 70% 3 to 40 words, 20% 40 to 300, 8% 300 to 1,500 and 2% 1,500 to 5,000.
    mutating func row(createdAt: Int64) -> SeedRow {
      let bucket = next(below: 100)
      let words =
        switch bucket {
        case 0..<70: next(in: 3...40)
        case 70..<90: next(in: 40...300)
        case 90..<98: next(in: 300...1_500)
        default: next(in: 1_500...5_000)
        }
      var text = ""
      text.reserveCapacity(words * 7)
      for index in 0..<words {
        if index > 0 { text.append(index % 14 == 0 ? ". " : " ") }
        text.append(Self.vocabulary[Int(next(below: UInt64(Self.vocabulary.count)))])
      }
      text.append(".")
      let app = Self.apps[Int(next(below: UInt64(Self.apps.count)))]
      return SeedRow(
        createdAt: createdAt, recordingMs: Int64(words) * 400 + 300,
        mode: next(below: 2) == 0 ? "toggle" : "pushToTalk", app: app, text: text, words: words)
    }

    private static let vocabulary = [
      "the", "meeting", "notes", "we", "should", "ship", "this", "on", "Friday", "and", "then", "review",
      "budget", "with", "team", "please", "send", "update", "about", "project", "timeline", "because",
      "customer", "asked", "for", "a", "quick", "summary", "of", "results", "next", "week", "draft",
      "email", "to", "design", "feedback", "is", "mostly", "positive", "but", "layout", "needs", "work",
      "remember", "call", "Anna", "tomorrow", "morning", "invoice", "numbers", "look", "right", "now",
    ]

    private static let apps: [(name: String, bundleID: String)] = [
      ("Notes", "com.apple.Notes"), ("Mail", "com.apple.mail"), ("Slack", "com.tinyspeck.slackmacgap"),
      ("Safari", "com.apple.Safari"), ("Xcode", "com.apple.dt.Xcode"), ("Messages", "com.apple.MobileSMS"),
    ]
  }
#endif
