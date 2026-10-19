import AppKit
import DesignSystem
import Hotkeys
import Reporting
import Storage
import SwiftUI

/// The setup banner, then the range's stats, its chart, the top apps and the last
/// months. New dictations update it without a reload.
struct HomeView: View {
  let model: AppModel

  private enum Phase: Equatable {
    case loading
    case loaded(HomeReport)
    case failed
  }

  @AppStorage(Self.rangeKey) private var range = ReportRange.week
  @State private var phase: Phase
  /// Bumped by Try Again to restart the observation.
  @State private var attempt = 0
  @State private var reportVersion = 0
  @State private var openReport = ScreenOpenReport()

  private static let rangeKey = "home.range"

  /// Opens on the last report it showed, if any, so the first frame has the dashboard.
  init(model: AppModel) {
    self.model = model
    let range = UserDefaults.standard.string(forKey: Self.rangeKey).flatMap(ReportRange.init) ?? .week
    let cached: HomeReport? =
      if case .ready(let db) = model.history.state { model.history.cache.report(range, in: db) } else { nil }
    _phase = State(initialValue: cached.map(Phase.loaded) ?? .loading)
  }

  var body: some View {
    content
      .navigationTitle("Home")
      .task(id: Query(database: databaseID, range: range, attempt: attempt)) { await observe() }
      .onChange(of: reportVersion) { reportShownAfterCommit() }
      .onAppear { if case .loaded = phase { reportVersion &+= 1 } }
  }

  private func reportShownAfterCommit() { Task { reportShown() } }

  private func reportShown() {
    guard case .loaded(let report) = phase else { return }
    if openReport.markReported() {
      ScreenSignposts.homeOpened(after: openReport.sinceOpened)
    }
    ScreenSignposts.homeUpdated(sessions: report.lifetime.sessions)
  }

  private struct Query: Equatable {
    var database: ObjectIdentifier?
    var range: ReportRange
    var attempt: Int
  }

  private var databaseID: ObjectIdentifier? {
    guard case .ready(let db) = model.history.state else { return nil }
    return ObjectIdentifier(db)
  }

  private func observe() async {
    switch model.history.state {
    case .opening:
      phase = .loading
    case .failed:
      phase = .failed
    case .ready(let db):
      do {
        for try await report in db.homeReport(range: range) {
          if !openReport.isReported, case .loading = phase {
            ScreenSignposts.firstValue(screen: "home", after: openReport.sinceOpened)
          }
          model.history.cache.store(report, for: range, in: db)
          guard phase != .loaded(report) else { continue }
          phase = .loaded(report)
          reportVersion &+= 1
        }
      } catch is CancellationError {
      } catch {
        phase = .failed
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .loading:
      page { Color.clear }
    case .failed:
      page {
        ContentUnavailableView {
          Label("Could not load your stats", systemImage: "exclamationmark.triangle")
        } description: {
          Text("Your dictations are safe on this Mac. Try again.")
        } actions: {
          Button("Try Again", action: tryAgain).appButton()
        }
      }
    case .loaded(let report) where report.lifetime.sessions == 0:
      Welcome(
        shortcut: toggle ?? pushToTalk, setup: SetupStep(model),
        isRecording: model.feedback.phase.showsRecording
      ) { model.screen = $0 }
      .padding(Space.xl)
    case .loaded(let report):
      ScrollView {
        VStack(alignment: .leading, spacing: Space.xxl.points) {
          SetupBanner(model: model)
          Dashboard(report: report, range: $range)
        }
        .padding(Space.xl)
      }
    }
  }

  /// A full-height state under the setup banner.
  private func page(@ViewBuilder _ state: () -> some View) -> some View {
    VStack(spacing: Space.xl.points) {
      SetupBanner(model: model)
      state().frame(maxHeight: .infinity)
    }
    .padding(Space.xl)
  }

  private var pushToTalk: Welcome.Shortcut? {
    model.shortcuts.bindings.trigger(for: .pushToTalk).map { .init(gesture: .hold, keys: $0.keyCaps) }
  }

  private var toggle: Welcome.Shortcut? {
    guard let trigger = model.shortcuts.bindings.trigger(for: .toggle) else { return nil }
    return switch trigger {
    case .chord: .init(gesture: .press, keys: trigger.keyCaps)
    case .doubleTap(let key): .init(gesture: .doubleTap, keys: [key.symbol])
    case .hold: .init(gesture: .hold, keys: trigger.keyCaps)
    }
  }

  private func tryAgain() {
    if case .failed = model.history.state {
      model.reopenDatabase()
    } else {
      phase = .loading
      attempt += 1
    }
  }
}

extension ReportRange {
  var title: String {
    switch self {
    case .week: "7 days"
    case .month: "30 days"
    case .quarter: "90 days"
    case .year: "12 months"
    }
  }

  /// "past 7 days", for detail lines and empty states.
  var phrase: String { "past \(title)" }
}

/// What is still missing before dictation works, the button that fixes it and where it goes.
/// The Home banner shows it over the dashboard; the empty Home makes it the page's action.
struct SetupStep {
  let message: String
  let action: String
  let screen: Screen

  @MainActor init?(_ model: AppModel) {
    guard model.needsSetup else { return nil }
    let canDictate = model.shortcuts.accessibilityGranted && model.input.access != .denied
    action = canDictate ? "Open Models" : "Open Settings"
    screen = canDictate ? .models : .settings
    message =
      if !model.shortcuts.accessibilityGranted {
        "OpenVocally needs Accessibility to paste into other apps."
      } else if model.input.access == .denied {
        "OpenVocally needs the microphone to hear you."
      } else if model.models.runtime == .failed {
        "The speech model couldn't load. Open Models to check it."
      } else {
        "Download a speech model to start dictating."
      }
  }
}

private struct SetupBanner: View {
  let model: AppModel

  var body: some View {
    if let step = SetupStep(model) {
      Banner(tone: .attention, title: "Finish setting up", message: step.message) {
        Button(step.action) { model.screen = step.screen }
          .appButton(.primary, size: .small)
      }
    }
  }
}
