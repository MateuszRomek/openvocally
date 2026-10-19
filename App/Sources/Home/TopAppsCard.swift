import AppKit
import DesignSystem
import Hotkeys
import Reporting
import Storage
import SwiftUI

/// The top five apps by words, and every app in a sheet.
struct TopAppsCard: View {
  let report: HomeReport
  @State private var showingAll = false

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Space.m.points) {
        HStack(alignment: .firstTextBaseline) {
          SectionHeader(title: "Top apps")
          Spacer()
          if !report.apps.isEmpty {
            Button("All Apps") { showingAll = true }.appButton(.secondary, size: .small)
          }
        }
        if report.apps.isEmpty {
          Text("No dictation in the \(report.range.phrase)")
            .textStyle(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          VStack(spacing: Space.m.points) {
            ForEach(report.apps.prefix(Self.shown)) { app in
              ShareRow(
                name: app.name, words: app.words, share: app.share, fraction: fraction(app.words)
              ) {
                AppIcon(bundleID: app.bundleID)
              }
            }
            if let other = OtherApps(report.apps, after: Self.shown) {
              ShareRow(
                name: "\(other.count) more \(other.count == 1 ? "app" : "apps")", words: other.words,
                share: other.share, fraction: fraction(other.words), secondary: true
              ) {
                Image(systemName: "square.grid.2x2").resizable().scaledToFit().padding(Space.xxs)
                  .foregroundStyle(.secondary)
                  .frame(width: IconSize.row.points, height: IconSize.row.points)
              }
              // A row, not a bordered button, so it matches the rows above in an inactive window too.
              .contentShape(.rect)
              .onTapGesture { showingAll = true }
              .accessibilityAddTraits(.isButton)
              .accessibilityAction { showingAll = true }
              .accessibilityHint("Shows every app")
            }
          }
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .sheet(isPresented: $showingAll) {
      AllAppsSheet(apps: report.apps, range: report.range)
    }
  }

  /// Home lists the top five and folds the rest into one row.
  static let shown = 5

  private func fraction(_ words: Int) -> Double {
    min(1, Double(words) / Double(max(1, report.apps.first?.words ?? 1)))
  }
}

/// One app, or the folded rest, with its words, share and a bar against the top app.
private struct ShareRow<Icon: View>: View {
  let name: String
  let words: Int
  /// Percent of the range's words.
  let share: Double
  /// The bar's length, against the top app's words.
  let fraction: Double
  /// The folded rest reads quieter than a named app.
  var secondary = false
  @ViewBuilder let icon: Icon

  var body: some View {
    HStack(spacing: Space.s.points) {
      icon
      VStack(alignment: .leading, spacing: Space.xs.points) {
        HStack(alignment: .firstTextBaseline) {
          Text(name).textStyle(.body).lineLimit(1)
            .foregroundStyle(secondary ? .secondary : .primary)
          Spacer(minLength: Space.s.points)
          Text(words.formatted()).textStyle(.body).monospacedDigit()
          Text(shareText).textStyle(.callout).monospacedDigit().foregroundStyle(.secondary)
            .frame(minWidth: Self.shareWidth, alignment: .trailing)
        }
        ShareBar(fraction: fraction, faded: secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(name)
    .accessibilityValue("\(words.formatted()) words, \(shareText)")
  }

  private var shareText: String { (share / 100).formatted(.percent.precision(.fractionLength(0))) }

  /// Fits "100%" so the words column lines up.
  static var shareWidth: CGFloat { 34 }
}

/// A thin bar in the secondary ink, like Screen Time's, so the top app reads as the longest.
private struct ShareBar: View {
  let fraction: Double
  var faded = false

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(faded ? .tertiary : .secondary)
        .frame(width: max(Self.height, proxy.size.width * fraction))
    }
    .frame(height: Self.height)
  }

  static let height: CGFloat = 4
}

/// Every app in the range, sortable, with its share, sessions and pace.
private struct AllAppsSheet: View {
  let apps: [AppUsage]
  let range: ReportRange
  @State private var order = [KeyPathComparator(\AppUsage.words, order: .reverse)]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(title: "All apps", detail: range.phrase.capitalizedFirst)
        .padding(Space.l)
      Table(sorted, sortOrder: $order) {
        TableColumn("App", value: \.name) { app in
          HStack(spacing: Space.s.points) {
            AppIcon(bundleID: app.bundleID)
            Text(app.name).lineLimit(1)
          }
        }
        .width(min: 140, ideal: 200)
        TableColumn("Words", value: \.words) { Text($0.words.formatted()).monospacedDigit() }
          .width(Self.numberColumn)
          .alignment(.trailing)
        TableColumn("Share", value: \.share) {
          Text(($0.share / 100).formatted(.percent.precision(.fractionLength(1)))).monospacedDigit()
        }
        .width(Self.numberColumn)
        .alignment(.trailing)
        TableColumn("Sessions", value: \.sessions) { Text($0.sessions.formatted()).monospacedDigit() }
          .width(Self.numberColumn)
          .alignment(.trailing)
        TableColumn("WPM", value: \.sortableWPM) { app in
          Text(app.averageWPM.map { Int($0.rounded()).formatted() } ?? "–").monospacedDigit()
        }
        .width(Self.numberColumn)
        .alignment(.trailing)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .appButton(.primary)
          .keyboardShortcut(.defaultAction)
      }
      .padding(Space.l)
    }
    .frame(minWidth: 640, minHeight: 360)
  }

  private var sorted: [AppUsage] { apps.sorted(using: order) }

  /// Fits "Sessions" and a five-digit count.
  private static let numberColumn: CGFloat = 76
}

extension AppUsage {
  fileprivate var sortableWPM: Double { averageWPM ?? -1 }
}
