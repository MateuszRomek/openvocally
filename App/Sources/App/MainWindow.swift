import DesignSystem
import SwiftUI

#if FEATURE_AGENTS
  import Agents
#endif

/// The main window's screens. Settings is one of them, so it opens in the window,
/// not in a separate one, from the sidebar footer.
enum Screen: String, CaseIterable, Identifiable {
  case home
  case transcripts
  #if FEATURE_AGENTS
    case agents
  #endif
  case models
  case settings

  var id: Self { self }

  /// The sidebar's top rows. Settings sits in its footer.
  static let primary = allCases.filter { $0 != .settings }

  var title: String {
    switch self {
    case .home: "Home"
    case .transcripts: "Transcripts"
    #if FEATURE_AGENTS
      case .agents: "Agents"
    #endif
    case .models: "Models"
    case .settings: "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .home: "house"
    case .transcripts: "text.bubble"
    #if FEATURE_AGENTS
      case .agents: "bubble.left.and.text.bubble.right"
    #endif
    case .models: "cpu"
    case .settings: "gearshape"
    }
  }
}

struct MainWindow: View {
  @Bindable var model: AppModel
  @AppStorage(WindowBackground.defaultsKey) private var background = WindowBackground.solid
  @Environment(\.openWindow) private var openWindow
  #if DEBUG
    @State private var columns = Self.initialColumns
  #endif
  #if FEATURE_AGENTS
    @State private var agentsActions = AgentsActions()
  #endif

  var body: some View {
    splitView
      .frame(minHeight: 550)
      #if FEATURE_AGENTS
        .agentsAlerts(agentsActions, agents: model.agents)
      #endif
      .windowBackground(background)
      // The Dock paths have no SwiftUI environment, so they reopen the window with this one.
      .onAppear { model.windowOpener = openWindow }
  }

  /// Debug takes the sidebar's visibility from `-sidebarCollapsed`; Release leaves it to the split
  /// view, which restores what the window last saved.
  @ViewBuilder private var splitView: some View {
    #if DEBUG
      NavigationSplitView(columnVisibility: $columns) {
        sidebar
      } detail: {
        detailColumn
      }
    #else
      NavigationSplitView {
        sidebar
      } detail: {
        detailColumn
      }
    #endif
  }

  private var sidebar: some View {
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
      } content: {
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
  }

  private var detailColumn: some View {
    detail
      #if DEBUG
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: {
          TranscriptsHarness.driver.contentFrame = $0
        }
      #endif
  }

  #if DEBUG
    /// `-sidebarCollapsed YES` or `NO` opens with the sidebar hidden or shown, so a screenshot
    /// doesn't depend on the state the window last saved.
    private static var initialColumns: NavigationSplitViewVisibility {
      switch UserDefaults.standard.object(forKey: "sidebarCollapsed") {
      case nil: .automatic
      case _ where UserDefaults.standard.bool(forKey: "sidebarCollapsed"): .detailOnly
      default: .all
      }
    }
  #endif

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
    #if FEATURE_AGENTS
      case .agents:
        AgentsScreen(
          agents: model.agents, actions: agentsActions, databaseFailed: model.history.isFailed,
          retry: model.reopenDatabase)
    #endif
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
          "Update Available", detail: "Version \(version)", systemImage: "arrow.down.circle.fill",
          action: updates.showAvailableUpdate)
      case .readyToInstall(let version):
        SidebarNotice(
          "Restart to Update", detail: "Version \(version)", systemImage: "arrow.clockwise.circle.fill",
          action: updates.installNow)
      }
    }
    .transition(SidebarNotice.entrance(reduceMotion: reduceMotion))
    .animation(reduceMotion ? nil : Motion.windowReveal.animation, value: updates.state)
  }
}
