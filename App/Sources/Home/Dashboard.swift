import AppKit
import DesignSystem
import Hotkeys
import Reporting
import Storage
import SwiftUI

struct Dashboard: View {
  let report: HomeReport
  @Binding var range: ReportRange

  /// Lazy, so the cards below the window's bottom are built when they scroll in, not on every
  /// open and every live resize.
  var body: some View {
    LazyVStack(alignment: .leading, spacing: Space.m.points) {
      // In the page, not the toolbar: a toolbar item that comes and goes with the screen made
      // every switch to and from Home rebuild the toolbar, about 40 ms of each open.
      Picker("Range", selection: $range) {
        ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .frame(maxWidth: .infinity, alignment: .trailing)
      Stats(report: report)
        #if DEBUG
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            TranscriptsHarness.driver.statsFrame = $0
          }
        #endif
      TimelineCard(report: report)
      Pair {
        TopAppsCard(report: report)
      } trailing: {
        MonthsCard(months: report.months)
      }
      #if DEBUG
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: {
          TranscriptsHarness.driver.pairFrame = $0
        }
      #endif
      HoursCard(report: report)
    }
  }
}

/// Two cards side by side at equal height while both keep room for a chart, else stacked.
private struct Pair<Leading: View, Trailing: View>: View {
  @ViewBuilder let leading: Leading
  @ViewBuilder let trailing: Trailing

  var body: some View {
    Columns(minWidth: Self.minWidth) {
      leading.frame(maxHeight: .infinity, alignment: .top)
      trailing.frame(maxHeight: .infinity, alignment: .top)
    }
  }

  static var minWidth: CGFloat { 340 }
}

/// Four tiles; a change shows only when the previous window had enough use.
private struct Stats: View {
  let report: HomeReport

  var body: some View {
    Columns(minWidth: Self.minWidth) {
      wordsPerMinute
      words
      lifetime
      time
    }
  }

  /// Four fit side by side from about 800 points.
  static var minWidth: CGFloat { 180 }

  private var wordsPerMinute: some View {
    StatTile(
      value: Int(report.summary.averageWPM.rounded()).formatted(), label: "Words per minute",
      detail: "Average pace"
    ) {
      DeltaTag(percent: report.deltas.averageWPM, range: report.range)
    }
    .tileFrame()
  }

  private var words: some View {
    StatTile(
      value: report.summary.words.formatted(), label: "Words", detail: report.range.phrase.capitalizedFirst
    ) {
      DeltaTag(percent: report.deltas.words, range: report.range)
    }
    .tileFrame()
  }

  private var lifetime: some View {
    StatTile(value: report.lifetime.words.formatted(), label: "Lifetime words", detail: "All sessions")
      .tileFrame()
  }

  private var time: some View {
    StatTile(
      value: ReportFormat.minutes(report.summary.totalMinutes), label: "Dictation time",
      detail: averageSession
    ) {
      DeltaTag(percent: report.deltas.totalMinutes, range: report.range)
    }
    .tileFrame()
  }

  private var averageSession: String {
    report.summary.averageSession.map { "\(ReportFormat.session($0)) per session" } ?? "No sessions"
  }
}

extension View {
  /// Every tile in a row takes the row's height.
  fileprivate func tileFrame() -> some View {
    frame(maxHeight: .infinity)
  }
}

/// The change against the previous window, with the arrow tinted for up or down.
private struct DeltaTag: View {
  let percent: Double?
  let range: ReportRange

  var body: some View {
    if let percent {
      Tag(ReportFormat.delta(percent), systemImage: symbol(percent), tint: tint(percent))
        .monospacedDigit()
        .help("Compared with the \(range.title) before")
        .accessibilityLabel("\(ReportFormat.delta(percent)) compared with the \(range.title) before")
    }
  }

  /// Follows the shown text, so "0.0%" gets a flat arrow and no color.
  private func direction(_ percent: Double) -> Double {
    (percent * 10).rounded() / 10
  }

  private func symbol(_ percent: Double) -> String {
    direction(percent) > 0 ? "arrow.up.right" : direction(percent) < 0 ? "arrow.down.right" : "arrow.right"
  }

  private func tint(_ percent: Double) -> SemanticColor? {
    direction(percent) > 0 ? .success : direction(percent) < 0 ? .destructive : nil
  }
}
