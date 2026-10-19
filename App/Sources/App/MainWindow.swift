import DesignSystem
import SwiftUI

/// The main window's screens. Settings is one of them, so it opens in the window,
/// not in a separate one, from the sidebar footer.
enum Screen: String, CaseIterable, Identifiable {
  case home
  case transcripts
  case models
  case settings

  var id: Self { self }

  static let primary: [Screen] = [.home, .transcripts, .models]

  var title: String {
    switch self {
    case .home: "Home"
    case .transcripts: "Transcripts"
    case .models: "Models"
    case .settings: "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .home: "house"
    case .transcripts: "text.bubble"
    case .models: "cpu"
    case .settings: "gearshape"
    }
  }
}

struct MainWindow: View {
  @Bindable var model: AppModel
  @AppStorage(WindowBackground.defaultsKey) private var background = WindowBackground.solid
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      List {
        ForEach(Screen.primary) { screen in
          SidebarRow(
            screen.title, systemImage: screen.symbol, isSelected: model.screen == screen,
            action: { model.screen = screen }
          )
          .listRowInsets(EdgeInsets())
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarFooter {
          UpdateNotice(updates: model.updates)
          SidebarRow(
            Screen.settings.title, systemImage: Screen.settings.symbol,
            isSelected: model.screen == .settings, action: { model.screen = .settings }
          ) {
            if model.needsSetup { StatusIcon(.attention) }
          }
          .accessibilityValue(model.needsSetup ? "Needs setup" : "")
        }
      }
      .navigationSplitViewColumnWidth(200)
    } detail: {
      detail
        #if DEBUG
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            TranscriptsHarness.driver.contentFrame = $0
          }
        #endif
    }
    .frame(minHeight: 550)
    .windowBackground(background)
    // The Dock paths have no SwiftUI environment, so they reopen the window with this one.
    .onAppear { model.windowOpener = openWindow }
  }

  /// The detail column's minimum width. It sits on each screen, not the whole split view: there
  /// it squeezed the toolbar while the sidebar animated, so the title jumped and the sidebar button
  /// fell into the overflow menu. Transcripts sets it only on its loading and empty states:
  /// a minimum around its list or its inspector made the inspector open in one frame.
  static let detailMinWidth: CGFloat = 568

  @ViewBuilder private var detail: some View {
    switch model.screen {
    case .home: HomeView(model: model).frame(minWidth: Self.detailMinWidth)
    case .transcripts:
      TranscriptsView(database: model.history.state, cache: model.history.cache, retry: model.reopenDatabase)
    case .models: ModelsView(library: model.models).frame(minWidth: Self.detailMinWidth)
    case .settings: SettingsView(model: model).frame(minWidth: Self.detailMinWidth)
    }
  }
}

/// The sidebar's update notice. Shown only while an update waits for the user.
private struct UpdateNotice: View {
  let updates: Updates
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      switch updates.state {
      case .none: EmptyView()
      case .available(let version):
        SidebarNotice(
          "Update Available", detail: version, systemImage: "arrow.down.circle.fill",
          action: updates.showAvailableUpdate)
      case .readyToInstall(let version):
        SidebarNotice(
          "Restart to Update", detail: version, systemImage: "arrow.clockwise.circle.fill",
          action: updates.installNow)
      }
    }
    .transition(SidebarNotice.entrance(reduceMotion: reduceMotion))
    .animation(reduceMotion ? nil : Motion.windowReveal.animation, value: updates.state)
  }
}
