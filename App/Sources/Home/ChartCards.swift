import AppKit
import DesignSystem
import Hotkeys
import Reporting
import Storage
import SwiftUI

/// Words by day, week or month, following the range, as an area chart.
struct TimelineCard: View {
  let report: HomeReport

  var body: some View {
    Card {
      TimeChart(
        title, points: report.timeline.points, unit: report.range.bucket.component,
        style: .area, noun: "words",
        detail: "\(report.summary.words.formatted()) words in total",
        emptyText: "No dictation in the \(report.range.phrase)")
    }
  }

  private var title: String {
    switch report.range.bucket {
    case .day: "Words by day"
    case .week: "Words by week"
    case .month: "Words by month"
    }
  }
}

/// The range's words by weekday and hour.
struct HoursCard: View {
  let report: HomeReport

  var body: some View {
    Card {
      WeekHeatmap(
        "When you dictate",
        values: (0..<7).map { day in report.hours.filter { $0.weekday == day }.map(\.words) },
        noun: "words", emptyText: "No dictation in the \(report.range.phrase)")
    }
  }
}

struct MonthsCard: View {
  let months: [WordBucket]
  @AppStorage("home.monthCount") private var count = 6

  var body: some View {
    Card {
      TimeChart(
        "Monthly output", points: months.suffix(count).points, unit: .month, style: .bars, noun: "words",
        detail: "\(months.suffix(count).reduce(0) { $0 + $1.words }.formatted()) words in total",
        emptyText: "No dictation in the last \(count) months"
      ) {
        Picker("Months", selection: $count) {
          Text("6 months").tag(6)
          Text("12 months").tag(12)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
      }
    }
  }
}

extension Collection<WordBucket> {
  fileprivate var points: [TimePoint] { map { TimePoint(start: $0.start, value: Double($0.words)) } }
}
