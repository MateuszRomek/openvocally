import Foundation
import GRDB
import Reporting

extension AppDatabase {
  /// Emits Home's report for `range`, again after every saved dictation. Each emission reads
  /// the clock and the calendar afresh, so the windows end at the moment of the change.
  public func homeReport(range: ReportRange, calendar: Calendar = .current)
    -> some AsyncSequence<HomeReport, any Error>
  {
    ValueObservation.tracking { db in
      try Self.fetchReport(db, range: range, now: .now, calendar: calendar)
    }
    .values(in: writer)
  }

  public func homeReport(range: ReportRange, now: Date, calendar: Calendar) throws -> HomeReport {
    try writer.read { try Self.fetchReport($0, range: range, now: now, calendar: calendar) }
  }

  /// Loads rows only for the range's current window, which the chart, apps and hours need one
  /// by one. The previous window, the months and the lifetime come back as sums, so the cost
  /// follows the range, not the whole history.
  private static func fetchReport(_ db: Database, range: ReportRange, now: Date, calendar: Calendar) throws
    -> HomeReport
  {
    let windows = HomeReport.windows(range: range, now: now, calendar: calendar)
    let nowMs = unixMilliseconds(now)
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT s.started_at, m.word_count, m.effective_ms, s.target_app_name, s.target_bundle_id
        FROM sessions s JOIN session_metrics m ON m.session_id = s.id
        WHERE s.started_at >= ? AND s.started_at < ?
        ORDER BY s.started_at
        """,
      arguments: [unixMilliseconds(windows.current.lowerBound), nowMs])
    let current = rows.map { row in
      SessionMetric(
        startedAt: date(unixMilliseconds: row[0]),
        words: row[1],
        duration: .milliseconds(row[2] as Int64),
        appName: row[3],
        bundleID: row[4])
    }
    let previous = try Row.fetchOne(
      db,
      sql: """
        SELECT COALESCE(SUM(m.word_count), 0), COALESCE(SUM(MAX(m.effective_ms, 0)), 0), COUNT(*)
        FROM sessions s JOIN session_metrics m ON m.session_id = s.id
        WHERE s.started_at >= ? AND s.started_at < ?
        """,
      arguments: [
        unixMilliseconds(windows.previous.lowerBound), unixMilliseconds(windows.previous.upperBound),
      ])
    let totals = try Row.fetchOne(
      db,
      sql: """
        SELECT COALESCE(SUM(word_count), 0), COALESCE(SUM(MAX(effective_ms, 0)), 0), COUNT(*)
        FROM session_metrics
        """)
    let lifetime = Lifetime(
      words: totals?[0] ?? 0, time: .milliseconds(totals?[1] as Int64? ?? 0), sessions: totals?[2] ?? 0)
    return HomeReport(
      range: range, current: current,
      previous: Summary(
        words: previous?[0] ?? 0, time: .milliseconds(previous?[1] as Int64? ?? 0),
        sessions: previous?[2] ?? 0),
      months: try monthWords(db, now: now, calendar: calendar), lifetime: lifetime, now: now,
      calendar: calendar)
  }

  /// Words per month bucket in one pass over the index range, summed by SQLite.
  private static func monthWords(_ db: Database, now: Date, calendar: Calendar) throws -> [WordBucket] {
    let buckets = HomeReport.monthBuckets(now: now, calendar: calendar)
    guard let first = buckets.first, let last = buckets.last else { return buckets }
    let nowMs = unixMilliseconds(now)
    let ends = buckets.map { min(unixMilliseconds($0.end), nowMs) }
    let cases = ends.dropLast().enumerated().map { "WHEN s.started_at < ? THEN \($0.offset)" }.joined(
      separator: " ")
    var arguments = StatementArguments(ends.dropLast())
    arguments += [unixMilliseconds(first.start), min(unixMilliseconds(last.end), nowMs)]
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT CASE \(cases) ELSE \(buckets.count - 1) END AS bucket, SUM(m.word_count)
        FROM sessions s JOIN session_metrics m ON m.session_id = s.id
        WHERE s.started_at >= ? AND s.started_at < ?
        GROUP BY bucket
        """,
      arguments: arguments)
    var words = [Int](repeating: 0, count: buckets.count)
    for row in rows {
      let index: Int = row[0]
      if words.indices.contains(index) { words[index] = row[1] }
    }
    return zip(buckets, words).map { WordBucket(start: $0.start, end: $0.end, words: $1) }
  }
}
