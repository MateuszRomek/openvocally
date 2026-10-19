import Foundation
import Testing

@testable import Reporting

/// Warsaw, so the fixtures cross the 29 March 2026 switch to summer time.
let warsaw: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/Warsaw") ?? .gmt
  calendar.firstWeekday = 1
  return calendar
}()

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
  warsaw.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    ?? .distantPast
}

func metric(
  _ startedAt: Date, words: Int, seconds: Double = 60, app: String? = "Notes",
  bundle: String? = "com.apple.Notes"
) -> SessionMetric {
  SessionMetric(
    startedAt: startedAt, words: words, duration: .seconds(seconds), appName: app, bundleID: bundle)
}

let lifetime = Lifetime(words: 0, totalMinutes: 0, sessions: 0)

struct WindowTests {
  @Test func weekSubtractsWallClockDaysAcrossSummerTime() {
    let now = date(2026, 3, 31, 12)
    let windows = HomeReport.windows(range: .week, now: now, calendar: warsaw)
    #expect(windows.current == date(2026, 3, 24, 12)..<now)
    #expect(windows.previous == date(2026, 3, 17, 12)..<date(2026, 3, 24, 12))
    #expect(now.timeIntervalSince(windows.current.lowerBound) == 7 * 24 * 3600 - 3600)
  }

  @Test(arguments: [
    (ReportRange.month, date(2026, 9, 10, 9), date(2026, 8, 11, 9)),
    (.quarter, date(2026, 7, 12, 9), date(2026, 4, 13, 9)),
    (.year, date(2025, 10, 10, 9), date(2024, 10, 10, 9)),
  ])
  func previousWindowHasTheSameLength(range: ReportRange, currentStart: Date, previousStart: Date) {
    let windows = HomeReport.windows(range: range, now: date(2026, 10, 10, 9), calendar: warsaw)
    #expect(windows.current.lowerBound == currentStart)
    #expect(windows.previous == previousStart..<currentStart)
  }

  @Test func yearClampsTheLastDayOfFebruary() {
    let windows = HomeReport.windows(range: .year, now: date(2028, 2, 29, 8), calendar: warsaw)
    #expect(windows.current.lowerBound == date(2027, 2, 28, 8))
  }

  @Test func monthlyChartReadsThirteenMonthsBack() {
    let windows = HomeReport.windows(range: .week, now: date(2026, 10, 10, 9), calendar: warsaw)
    #expect(windows.months.lowerBound == date(2025, 9, 10, 9))
    #expect(windows.earliest == date(2025, 9, 10, 9))
  }
}

struct SummaryTests {
  @Test func emptyIsZero() {
    #expect(Summary([]) == Summary(averageWPM: 0, words: 0, totalMinutes: 0, sessions: 0))
    #expect(Summary([]).averageSession == nil)
  }

  @Test func roundsToTwoDecimals() {
    let summary = Summary([metric(.now, words: 10, seconds: 7)])
    #expect(summary == Summary(averageWPM: 85.71, words: 10, totalMinutes: 0.12, sessions: 1))
  }

  @Test func negativeDurationCountsAsZero() {
    let summary = Summary([metric(.now, words: 50, seconds: 60), metric(.now, words: 50, seconds: -30)])
    #expect(summary == Summary(averageWPM: 100, words: 100, totalMinutes: 1, sessions: 2))
    #expect(summary.averageSession == .seconds(30))
  }
}

struct DeltaTests {
  let now = date(2026, 10, 10, 12)

  /// `count` sessions of `seconds` each in the previous week, and one 300-word minute now.
  func report(previousSessions count: Int, seconds: Double, words: Int = 40) -> HomeReport {
    let previous = (0..<count).map { metric(date(2026, 9, 28, 9, $0), words: words, seconds: seconds) }
    return HomeReport(
      range: .week, metrics: previous + [metric(date(2026, 10, 9, 9), words: 300)], lifetime: lifetime,
      now: now, calendar: warsaw)
  }

  @Test func needFiveSessionsBefore() {
    #expect(report(previousSessions: 4, seconds: 600).deltas == .none)
  }

  @Test func needTenMinutesBefore() {
    #expect(report(previousSessions: 5, seconds: 119.9).deltas == .none)
  }

  @Test func comparesAtTheThreshold() {
    let deltas = report(previousSessions: 5, seconds: 120).deltas
    #expect(deltas == Deltas(averageWPM: 1400, words: 50, totalMinutes: -90, sessions: -80))
  }

  @Test func previousZeroHasNoDelta() {
    #expect(report(previousSessions: 5, seconds: 120, words: 0).deltas.words == nil)
  }

  @Test func halvesRoundUpLikeJavaScript() {
    #expect(rounded(-0.125) == -0.12)
    #expect(rounded(0.125) == 0.13)
  }
}

struct FormatTests {
  @Test(arguments: [
    (12.34, "+12.3%"), (-4, "-4.0%"), (0, "0.0%"), (999, "+999.0%"), (1200, "+999%"), (-1500, "-999%"),
  ])
  func delta(percent: Double, text: String) {
    #expect(ReportFormat.delta(percent) == text)
  }

  @Test(arguments: [(0.4, "0m"), (45, "45m"), (59.6, "1h 0m"), (125, "2h 5m"), (-3, "0m")])
  func minutes(value: Double, text: String) {
    #expect(ReportFormat.minutes(value) == text)
  }

  @Test(arguments: [(0.2, "1s"), (24.4, "24s"), (59.4, "59s"), (90, "2m"), (3720, "1h 2m")])
  func session(seconds: Double, text: String) {
    #expect(ReportFormat.session(.seconds(seconds)) == text)
  }
}

struct BucketTests {
  @Test func weekIsSevenDaysEndingToday() {
    let now = date(2026, 10, 10, 12)
    let report = HomeReport(
      range: .week,
      metrics: [
        metric(date(2026, 10, 3, 11), words: 1),
        metric(date(2026, 10, 4, 0, 30), words: 2),
        metric(date(2026, 10, 4, 23, 59), words: 3),
        metric(date(2026, 10, 10, 0, 1), words: 4),
      ],
      lifetime: lifetime, now: now, calendar: warsaw)
    #expect(report.timeline.map(\.start) == (4...10).map { date(2026, 10, $0) })
    #expect(report.timeline.map(\.words) == [5, 0, 0, 0, 0, 0, 4])
    #expect(report.summary.words == 9)
  }

  @Test func monthIsThirtyDays() {
    let report = HomeReport(
      range: .month, metrics: [], lifetime: lifetime, now: date(2026, 10, 10, 12), calendar: warsaw)
    #expect(report.timeline.count == 30)
    #expect(report.timeline.first?.start == date(2026, 9, 11))
    #expect(report.timeline.last?.end == date(2026, 10, 11))
  }

  @Test func dayOfTheClockChangeIsTwentyThreeHours() {
    let report = HomeReport(
      range: .week, metrics: [], lifetime: lifetime, now: date(2026, 3, 31, 12), calendar: warsaw)
    let switchDay = report.timeline.first { $0.start == date(2026, 3, 29) }
    #expect(switchDay.map { $0.end.timeIntervalSince($0.start) } == TimeInterval(23 * 3600))
  }

  @Test func quarterIsThirteenWeeksStartingMonday() {
    let now = date(2026, 10, 10, 12)
    let report = HomeReport(
      range: .quarter,
      metrics: [metric(date(2026, 10, 5, 0, 5), words: 9), metric(date(2026, 10, 4, 23, 55), words: 1)],
      lifetime: lifetime, now: now, calendar: warsaw)
    #expect(report.timeline.count == 13)
    #expect(report.timeline.first?.start == date(2026, 7, 13))
    #expect(report.timeline.last?.start == date(2026, 10, 5))
    #expect(report.timeline.suffix(2).map(\.words) == [1, 9])
  }

  @Test func yearIsTwelveMonthsEndingThisMonth() {
    let report = HomeReport(
      range: .year, metrics: [metric(date(2025, 11, 30, 23), words: 6)], lifetime: lifetime,
      now: date(2026, 10, 10, 12), calendar: warsaw)
    #expect(report.timeline.count == 12)
    #expect(report.timeline.first == WordBucket(start: date(2025, 11, 1), end: date(2025, 12, 1), words: 6))
    #expect(report.timeline.last?.start == date(2026, 10, 1))
  }

  @Test func monthlyChartIgnoresTheRange() {
    let report = HomeReport(
      range: .week,
      metrics: [
        metric(date(2025, 9, 20), words: 100),
        metric(date(2025, 11, 2), words: 7),
        metric(date(2026, 10, 1), words: 3),
      ],
      lifetime: lifetime, now: date(2026, 10, 10, 12), calendar: warsaw)
    #expect(report.months.count == 12)
    #expect(report.months.first?.start == date(2025, 11, 1))
    #expect(report.months.map(\.words) == [7] + Array(repeating: 0, count: 10) + [3])
    #expect(report.summary.words == 0)
  }
}

struct AppTests {
  @Test func ranksByWordsWithShareAndPace() {
    let report = HomeReport(
      range: .week,
      metrics: [
        metric(date(2026, 10, 9), words: 30, seconds: 30, app: "Notes", bundle: "com.apple.Notes"),
        metric(date(2026, 10, 9), words: 90, seconds: 60, app: "Slack", bundle: "com.tinyspeck.slackmacgap"),
        metric(date(2026, 10, 9), words: 30, seconds: 0, app: "Notes", bundle: "com.apple.Notes"),
        metric(date(2026, 10, 9), words: 0, seconds: 10, app: "Mail", bundle: nil),
        metric(date(2026, 10, 9), words: 30, seconds: 60, app: nil, bundle: nil),
      ],
      lifetime: lifetime, now: date(2026, 10, 10), calendar: warsaw)
    #expect(
      report.apps == [
        AppUsage(
          id: "com.tinyspeck.slackmacgap", name: "Slack", bundleID: "com.tinyspeck.slackmacgap", words: 90,
          share: 50, sessions: 1, averageWPM: 90),
        AppUsage(
          id: "com.apple.Notes", name: "Notes", bundleID: "com.apple.Notes", words: 60, share: 33.33,
          sessions: 2,
          averageWPM: 120),
        AppUsage(
          id: "unknown", name: "Unknown", bundleID: nil, words: 30, share: 16.67, sessions: 1, averageWPM: 30),
        AppUsage(id: "Mail", name: "Mail", bundleID: nil, words: 0, share: 0, sessions: 1, averageWPM: nil),
      ])
  }

  @Test func bundleWithoutNameUsesTheBundle() {
    let usage = AppUsage.rank([metric(.now, words: 1, app: nil, bundle: "com.example")])
    #expect(usage.map(\.name) == ["com.example"])
  }
}

struct OtherAppsTests {
  func app(_ name: String, words: Int) -> AppUsage {
    AppUsage(id: name, name: name, bundleID: nil, words: words, share: 0, sessions: 1, averageWPM: nil)
  }

  @Test func foldsTheAppsPastTheLimit() {
    let apps = [
      app("A", words: 50), app("B", words: 30), app("C", words: 15), app("D", words: 5), app("E", words: 0),
    ]
    #expect(OtherApps(apps, after: 2) == OtherApps(count: 2, words: 20, share: 20))
  }

  @Test func nilWhenNothingPastTheLimitHasWords() {
    #expect(OtherApps([app("A", words: 3), app("B", words: 1)], after: 2) == nil)
    #expect(OtherApps([app("A", words: 3), app("B", words: 0)], after: 1) == nil)
  }

  @Test func shareRoundsToTwoDecimals() {
    #expect(OtherApps([app("A", words: 2), app("B", words: 1)], after: 1)?.share == 33.33)
  }
}

struct HourOfWeekTests {
  @Test func mondayFirstInLocalTime() {
    let report = HomeReport(
      range: .week,
      metrics: [
        metric(date(2026, 10, 5, 9, 59), words: 4),
        metric(date(2026, 10, 5, 9, 1), words: 6),
        metric(date(2026, 10, 4, 23, 30), words: 7),
      ],
      lifetime: lifetime, now: date(2026, 10, 10, 12), calendar: warsaw)
    #expect(report.hours.count == 168)
    #expect(report.hours[9] == HourOfWeek(weekday: 0, hour: 9, words: 10))
    #expect(report.hours[6 * 24 + 23] == HourOfWeek(weekday: 6, hour: 23, words: 7))
    #expect(report.hours.reduce(0) { $0 + $1.words } == 17)
  }
}
