import Foundation
import GRDB
import Reporting
import Testing

@testable import DictationCore
@testable import Storage

struct ReportingQueryTests {
  let now = Date(timeIntervalSince1970: 1_760_000_000)

  func save(_ database: AppDatabase, _ text: String, daysAgo: Double, app: TargetApp?) async throws {
    let pressedAt = HostTime.now()
    try await database.save(
      entry(text, pressedAt: pressedAt, recording: .seconds(30), target: app),
      savedAt: now.addingTimeInterval(-daysAgo * 86_400), hostNow: pressedAt)
  }

  @Test func readsTheRangeAndLifetimeTotals() async throws {
    let database = try AppDatabase.inMemory()
    let slack = TargetApp(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
    try await save(database, "one two three four", daysAgo: 1, app: slack)
    try await save(database, "five six", daysAgo: 2, app: nil)
    try await save(database, "old words here", daysAgo: 400, app: slack)

    let report = try database.homeReport(range: .week, now: now, calendar: Calendar(identifier: .gregorian))
    #expect(report.summary == Summary(averageWPM: 6, words: 6, totalMinutes: 1, sessions: 2))
    #expect(report.lifetime == Lifetime(words: 9, totalMinutes: 1.5, sessions: 3))
    #expect(report.apps.map(\.name) == ["Slack", "Unknown"])
    #expect(report.timeline.map(\.words).reduce(0, +) == 6)
  }

  /// The query sums the previous window, the months and the lifetime in SQLite; the result must
  /// match the report built from every row.
  @Test(arguments: ReportRange.allCases)
  func sumsMatchTheReportBuiltFromRows(range: ReportRange) async throws {
    let database = try AppDatabase.inMemory()
    let calendar = Calendar(identifier: .gregorian)
    let apps = [TargetApp(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"), nil]
    let days: [Double] = [
      0.2, 0.9, 3, 6.5, 8, 12, 15, 29, 31, 45, 70, 89, 95, 140, 170, 200, 300, 364, 370, 390, 410,
    ]
    for (index, daysAgo) in days.enumerated() {
      let words = (0...(index % 7)).map { "w\($0)" }.joined(separator: " ")
      try await save(database, words, daysAgo: daysAgo, app: apps[index % 2])
    }

    let metrics = try await database.writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT s.started_at, m.word_count, m.effective_ms, s.target_app_name, s.target_bundle_id
          FROM sessions s JOIN session_metrics m ON m.session_id = s.id ORDER BY s.started_at
          """
      ).map { row in
        SessionMetric(
          startedAt: Date(timeIntervalSince1970: Double(row[0] as Int64) / 1000), words: row[1],
          duration: .milliseconds(row[2] as Int64), appName: row[3], bundleID: row[4])
      }
    }
    let report = try database.homeReport(range: range, now: now, calendar: calendar)
    let lifetime = Lifetime(
      words: metrics.reduce(0) { $0 + $1.words },
      time: metrics.reduce(.zero) { $0 + max(.zero, $1.duration) },
      sessions: metrics.count)
    #expect(lifetime.sessions == days.count)
    let expected = HomeReport(
      range: range, metrics: metrics, lifetime: lifetime, now: now, calendar: calendar)
    #expect(report == expected)
    #expect(report.months.map(\.words).reduce(0, +) > 0)
  }

  @Test func emitsAgainAfterADictation() async throws {
    let database = try AppDatabase.inMemory()
    var reports = database.homeReport(range: .week).makeAsyncIterator()
    #expect(try await reports.next(isolation: #isolation)?.lifetime.sessions == 0)
    try await database.save(entry("hello there"))
    #expect(try await reports.next(isolation: #isolation)?.lifetime.words == 2)
  }
}
