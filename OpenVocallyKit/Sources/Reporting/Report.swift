import Foundation

/// The time range Home reports on.
public enum ReportRange: String, CaseIterable, Identifiable, Sendable {
  case week = "7d"
  case month = "30d"
  case quarter = "90d"
  case year = "12m"

  public var id: Self { self }

  /// What one bar of the range's chart covers.
  public enum Bucket: Sendable {
    case day
    case week
    case month

    public var component: Calendar.Component {
      switch self {
      case .day: .day
      case .week: .weekOfYear
      case .month: .month
      }
    }
  }

  public var bucket: Bucket {
    switch self {
    case .week, .month: .day
    case .quarter: .week
    case .year: .month
    }
  }

  var bucketCount: Int {
    switch self {
    case .week: 7
    case .month: 30
    case .quarter: 13
    case .year: 12
    }
  }

  /// Wall-clock subtraction in the calendar's time zone, like date-fns `subDays` and `subMonths`.
  func start(before end: Date, calendar: Calendar) -> Date {
    let step: DateComponents =
      switch self {
      case .week: DateComponents(day: -7)
      case .month: DateComponents(day: -30)
      case .quarter: DateComponents(day: -90)
      case .year: DateComponents(month: -12)
      }
    return calendar.date(byAdding: step, to: end) ?? end
  }
}

/// One saved dictation, as reporting sees it.
public struct SessionMetric: Sendable, Equatable {
  public let startedAt: Date
  public let words: Int
  /// The time the user spent dictating. Negative values count as zero.
  public let duration: Duration
  public let appName: String?
  public let bundleID: String?

  public init(startedAt: Date, words: Int, duration: Duration, appName: String?, bundleID: String?) {
    self.startedAt = startedAt
    self.words = words
    self.duration = duration
    self.appName = appName
    self.bundleID = bundleID
  }

  var minutes: Double { max(0, duration / .seconds(60)) }
}

/// Totals for a set of sessions. Rounded to two decimals.
public struct Summary: Sendable, Equatable {
  public let averageWPM: Double
  public let words: Int
  public let totalMinutes: Double
  public let sessions: Int

  public init(averageWPM: Double, words: Int, totalMinutes: Double, sessions: Int) {
    self.averageWPM = averageWPM
    self.words = words
    self.totalMinutes = totalMinutes
    self.sessions = sessions
  }

  public init(_ metrics: some Collection<SessionMetric>) {
    self.init(
      words: metrics.reduce(0) { $0 + $1.words },
      time: metrics.reduce(.zero) { $0 + max(.zero, $1.duration) },
      sessions: metrics.count)
  }

  /// From totals, such as a database sum. `time` counts negative durations as zero.
  public init(words: Int, time: Duration, sessions: Int) {
    let minutes = time / .seconds(60)
    self.init(
      averageWPM: minutes > 0 ? rounded(Double(words) / minutes) : 0,
      words: words,
      totalMinutes: rounded(minutes),
      sessions: sessions)
  }

  /// The average session length, or nil with no sessions.
  public var averageSession: Duration? {
    sessions > 0 ? .seconds(totalMinutes * 60 / Double(sessions)) : nil
  }

  /// A previous window this small would make every change look huge.
  var supportsComparison: Bool {
    sessions >= 5 && totalMinutes >= 10
  }
}

/// Percent change against the previous window of the same length. Nil when the
/// previous window is too small to compare against.
public struct Deltas: Sendable, Equatable {
  public let averageWPM: Double?
  public let words: Double?
  public let totalMinutes: Double?
  public let sessions: Double?

  public static let none = Deltas(averageWPM: nil, words: nil, totalMinutes: nil, sessions: nil)

  public init(averageWPM: Double?, words: Double?, totalMinutes: Double?, sessions: Double?) {
    self.averageWPM = averageWPM
    self.words = words
    self.totalMinutes = totalMinutes
    self.sessions = sessions
  }

  init(current: Summary, previous: Summary) {
    guard previous.supportsComparison else {
      self = .none
      return
    }
    self.init(
      averageWPM: percentChange(current.averageWPM, from: previous.averageWPM),
      words: percentChange(Double(current.words), from: Double(previous.words)),
      totalMinutes: percentChange(current.totalMinutes, from: previous.totalMinutes),
      sessions: percentChange(Double(current.sessions), from: Double(previous.sessions)))
  }
}

/// Words dictated in one chart bar.
public struct WordBucket: Sendable, Equatable, Identifiable {
  public let start: Date
  public let end: Date
  public let words: Int

  public var id: Date { start }

  public init(start: Date, end: Date, words: Int) {
    self.start = start
    self.end = end
    self.words = words
  }
}

/// Words dictated in one hour of the week, such as Tuesdays from 10:00 to 11:00.
public struct HourOfWeek: Sendable, Equatable, Identifiable {
  /// 0 is Monday, 6 is Sunday.
  public let weekday: Int
  /// 0 to 23 in the calendar's time zone.
  public let hour: Int
  public let words: Int

  public var id: Int { weekday * 24 + hour }

  public init(weekday: Int, hour: Int, words: Int) {
    self.weekday = weekday
    self.hour = hour
    self.words = words
  }
}

/// Words dictated into one app.
public struct AppUsage: Sendable, Equatable, Identifiable {
  /// The bundle id, else the app name, else "unknown".
  public let id: String
  public let name: String
  public let bundleID: String?
  public let words: Int
  /// Percent of the range's words, rounded to two decimals.
  public let share: Double
  public let sessions: Int
  /// Nil when the app has no words or no time.
  public let averageWPM: Double?

  public init(
    id: String, name: String, bundleID: String?, words: Int, share: Double, sessions: Int,
    averageWPM: Double?
  ) {
    self.id = id
    self.name = name
    self.bundleID = bundleID
    self.words = words
    self.share = share
    self.sessions = sessions
    self.averageWPM = averageWPM
  }

  /// Apps by words, most first. Ties keep the order the apps were first seen in.
  static func rank(_ metrics: [SessionMetric]) -> [AppUsage] {
    struct Tally {
      var name: String
      var bundleID: String?
      var words = 0
      var sessions = 0
      var minutes = 0.0
    }
    var order: [String] = []
    var tallies: [String: Tally] = [:]
    for metric in metrics {
      let key = metric.bundleID ?? metric.appName ?? "unknown"
      if tallies[key] == nil {
        order.append(key)
        tallies[key] = Tally(name: metric.appName ?? metric.bundleID ?? "Unknown", bundleID: metric.bundleID)
      }
      tallies[key]?.words += metric.words
      tallies[key]?.sessions += 1
      tallies[key]?.minutes += metric.minutes
    }
    let total = tallies.values.reduce(0) { $0 + $1.words }
    let ranked = order.enumerated().sorted { lhs, rhs in
      let (l, r) = (tallies[lhs.element]?.words ?? 0, tallies[rhs.element]?.words ?? 0)
      return l != r ? l > r : lhs.offset < rhs.offset
    }
    return ranked.compactMap { _, key in
      guard let tally = tallies[key] else { return nil }
      return AppUsage(
        id: key, name: tally.name, bundleID: tally.bundleID, words: tally.words,
        share: total > 0 ? rounded(Double(tally.words) / Double(total) * 100) : 0,
        sessions: tally.sessions,
        averageWPM: tally.words > 0 && tally.minutes > 0
          ? rounded(Double(tally.words) / tally.minutes) : nil)
    }
  }
}

/// The apps past the first few in the ranking, folded into one row.
public struct OtherApps: Sendable, Equatable {
  /// Apps with words among them.
  public let count: Int
  public let words: Int
  /// Percent of the range's words, rounded to two decimals.
  public let share: Double

  public init(count: Int, words: Int, share: Double) {
    self.count = count
    self.words = words
    self.share = share
  }

  /// Everything after the first `limit` apps, or nil when nothing after them has words.
  public init?(_ apps: [AppUsage], after limit: Int) {
    let rest = apps.dropFirst(limit).filter { $0.words > 0 }
    let words = rest.reduce(0) { $0 + $1.words }
    let total = apps.reduce(0) { $0 + $1.words }
    guard words > 0 else { return nil }
    self.init(count: rest.count, words: words, share: rounded(Double(words) / Double(total) * 100))
  }
}

/// Lifetime totals across every saved session.
public struct Lifetime: Sendable, Equatable {
  public let words: Int
  public let totalMinutes: Double
  public let sessions: Int

  public init(words: Int, totalMinutes: Double, sessions: Int) {
    self.words = words
    self.totalMinutes = totalMinutes
    self.sessions = sessions
  }

  /// From totals, such as a database sum, with minutes rounded like `Summary`.
  public init(words: Int, time: Duration, sessions: Int) {
    self.init(words: words, totalMinutes: rounded(time / .seconds(60)), sessions: sessions)
  }
}

/// Everything Home shows for one range.
public struct HomeReport: Sendable, Equatable {
  public let range: ReportRange
  public let summary: Summary
  public let deltas: Deltas
  public let lifetime: Lifetime
  /// The range's chart, oldest bar first.
  public let timeline: [WordBucket]
  /// The last 12 calendar months, oldest first, the current month included.
  public let months: [WordBucket]
  /// Every app with words in the range, most words first.
  public let apps: [AppUsage]
  /// The range's words in each of the week's 168 hours, Monday 0:00 first.
  public let hours: [HourOfWeek]

  /// The windows a report reads, so storage can fetch them in one pass.
  public struct Windows: Sendable, Equatable {
    public let current: Range<Date>
    public let previous: Range<Date>
    public let months: Range<Date>

    /// The earliest start of the three windows.
    var earliest: Date { min(previous.lowerBound, months.lowerBound) }
  }

  /// The current window ends now; the previous one is the same length just before it.
  /// The monthly chart reads 13 months back and keeps the last 12.
  public static func windows(range: ReportRange, now: Date, calendar: Calendar) -> Windows {
    let currentStart = range.start(before: now, calendar: calendar)
    let previousStart = range.start(before: currentStart, calendar: calendar)
    let monthsStart = calendar.date(byAdding: .month, value: -13, to: now) ?? now
    return Windows(
      current: currentStart..<now, previous: previousStart..<currentStart, months: monthsStart..<now)
  }

  /// Builds the report from every session since `windows(...).earliest`. The calendar sets the
  /// time zone; weeks start on Monday whatever its `firstWeekday`.
  public init(
    range: ReportRange, metrics: [SessionMetric], lifetime: Lifetime, now: Date, calendar: Calendar
  ) {
    let windows = Self.windows(range: range, now: now, calendar: calendar)
    self.init(
      range: range, current: metrics.filter { windows.current.contains($0.startedAt) },
      previous: Summary(metrics.filter { windows.previous.contains($0.startedAt) }),
      months: Self.buckets(
        .month, count: 12, metrics: metrics.filter { windows.months.contains($0.startedAt) }, now: now,
        calendar: calendar),
      lifetime: lifetime, now: now, calendar: calendar)
  }

  /// Builds the report from the current window's sessions and totals storage sums for the rest,
  /// so the previous window and the months never load row by row. `months` holds
  /// `monthBuckets(now:calendar:)` with their words.
  public init(
    range: ReportRange, current: [SessionMetric], previous: Summary, months: [WordBucket], lifetime: Lifetime,
    now: Date, calendar: Calendar
  ) {
    var calendar = calendar
    calendar.firstWeekday = 2
    let summary = Summary(current)
    self.range = range
    self.summary = summary
    self.deltas = Deltas(current: summary, previous: previous)
    self.lifetime = lifetime
    self.timeline = Self.buckets(
      range.bucket, count: range.bucketCount, metrics: current, now: now, calendar: calendar)
    self.months = months
    self.apps = AppUsage.rank(current)
    self.hours = Self.hours(current, calendar: calendar)
  }

  /// The monthly chart's 12 buckets, oldest first, with no words. A session counts in a bucket
  /// when it starts in `start..<min(end, now)`.
  public static func monthBuckets(now: Date, calendar: Calendar) -> [WordBucket] {
    buckets(.month, count: 12, metrics: [], now: now, calendar: calendar)
  }

  static func hours(_ metrics: [SessionMetric], calendar: Calendar) -> [HourOfWeek] {
    var words = [Int](repeating: 0, count: 7 * 24)
    for metric in metrics {
      let parts = calendar.dateComponents([.weekday, .hour], from: metric.startedAt)
      guard let weekday = parts.weekday, let hour = parts.hour else { continue }
      words[((weekday + 5) % 7) * 24 + hour] += metric.words
    }
    return words.enumerated().map {
      HourOfWeek(weekday: $0.offset / 24, hour: $0.offset % 24, words: $0.element)
    }
  }

  /// `count` buckets ending with the one that holds `now`. Sessions outside them are dropped.
  static func buckets(
    _ bucket: ReportRange.Bucket, count: Int, metrics: [SessionMetric], now: Date, calendar: Calendar
  ) -> [WordBucket] {
    let component = bucket.component
    func start(of date: Date) -> Date {
      calendar.dateInterval(of: component, for: date)?.start ?? date
    }
    let last = start(of: now)
    let starts = (0..<count).compactMap {
      calendar.date(byAdding: component, value: $0 - count + 1, to: last).map(start(of:))
    }
    var words: [Date: Int] = [:]
    for metric in metrics {
      words[start(of: metric.startedAt), default: 0] += metric.words
    }
    return starts.map { start in
      let end = calendar.date(byAdding: component, value: 1, to: start) ?? start
      return WordBucket(start: start, end: end, words: words[start] ?? 0)
    }
  }
}

/// Two decimals, halves rounded up like JavaScript's `Math.round`, so negative deltas match.
func rounded(_ value: Double) -> Double {
  (value * 100 + 0.5).rounded(.down) / 100
}

func percentChange(_ current: Double, from previous: Double) -> Double? {
  previous == 0 ? nil : rounded((current - previous) / abs(previous) * 100)
}
