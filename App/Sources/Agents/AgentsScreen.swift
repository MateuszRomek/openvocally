#if FEATURE_AGENTS
  import Agents
  import AgentsCore
  import DesignSystem
  import SwiftUI

  /// Two panes: every thread grouped under its project, and the selected thread's
  /// conversation, which takes the rest of the window. The app sidebar keeps only the Agents row.
  struct AgentsScreen: View {
    let agents: AgentsService?
    let actions: AgentsActions
    let databaseFailed: Bool
    let retry: () -> Void

    /// 260 + 308 is the window's 568 pt detail minimum, so opening Agents never resizes the window;
    /// the list gives up its last 20 pt first.
    static let listMinWidth: CGFloat = 260
    static let listIdealWidth: CGFloat = 280
    static let conversationMinWidth: CGFloat = 308

    @State private var groups: [Project.ID: ThreadGroup] = [:]
    /// Projects whose "Show more" was pressed, with how many threads each now shows.
    @State private var shown: [Project.ID: Int] = [:]
    @State private var selectedThread: AgentThread.ID?
    /// The toolbar band's height, which each pane's header fills.
    @State private var band: CGFloat = 0
    #if DEBUG
      @State private var createdAt = ContinuousClock.now
    #endif

    var body: some View {
      content
        .frame(minWidth: MainWindow.detailMinWidth)
        // Measured here, outside the panes, which ignore the top safe area and would read 0.
        .onGeometryChange(for: CGFloat.self) {
          $0.safeAreaInsets.top
        } action: {
          band = $0
        }
        .navigationTitle("Agents")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task(
          id: ThreadQuery(
            ready: agents != nil, shown: shown, waiting: agents?.waiting ?? [], selected: selectedThread)
        ) {
          await observeThreads()
        }
        .onAppear {
          guard let agents else { return }
          Task { await agents.refreshHealth() }
        }
        #if DEBUG
          .task(id: agents == nil) {
            guard agents != nil, AgentsLaunch.scenario != nil else { return }
            await AgentsLaunch.markReady()
          }
        #endif
    }

    @ViewBuilder private var content: some View {
      if let agents, agents.loadFailed {
        loadFailed { Task { try? await agents.load() } }
      } else if let agents {
        let thread = thread(selectedThread)
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            PaneHeader(title: "Threads", subtitle: nil) {
              IconButton("Add Project", systemImage: "folder.badge.plus") {
                Task { await actions.add(agents) }
              }
            }
            .frame(height: band)
            threadList(agents).frame(maxHeight: .infinity)
          }
          .frame(minWidth: Self.listMinWidth, idealWidth: Self.listIdealWidth, maxWidth: Self.listIdealWidth)
          Divider()
          VStack(spacing: 0) {
            PaneHeader(
              title: thread?.title ?? "",
              subtitle: thread.map { thread in
                let project = agents.projects.first { $0.id == thread.projectID }?.project.name ?? ""
                return "\(thread.provider == .claude ? "Claude" : "Codex") · \(project)"
              }
            ) {
              EmptyView()
            }
            .frame(height: band)
            ConversationPane(
              agents: agents, thread: selectedThread,
              isWaiting: selectedThread.map(agents.waiting.contains) ?? false
            )
            .frame(maxHeight: .infinity)
          }
          .frame(minWidth: Self.conversationMinWidth, maxWidth: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
      } else if databaseFailed {
        loadFailed(retry: retry)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }

    private func loadFailed(retry: @escaping () -> Void) -> some View {
      ContentUnavailableView {
        Label("Could not load projects", systemImage: "exclamationmark.triangle")
      } actions: {
        Button("Try Again", action: retry).appButton()
      }
    }

    @ViewBuilder private func threadList(_ agents: AgentsService) -> some View {
      if agents.projects.isEmpty {
        ContentUnavailableView {
          Label("No projects", systemImage: "folder")
        } description: {
          Text("Add a folder to start threads in it.")
        } actions: {
          Button("Add Project") { Task { await actions.add(agents) } }.appButton()
        }
      } else {
        List(selection: $selectedThread) {
          // Plain rows, not Sections: a List pins a Section's header with its own background and
          // line, so the top project would look unlike the rest.
          ForEach(agents.projects) { row in
            ProjectHeader(row: row, actions: actions, agents: agents)
              .padding(.top, row.id == agents.projects.first?.id ? Space.xxs : Space.m)
              .listRowSeparator(.hidden)
              .selectionDisabled()
            projectThreads(row, agents)
          }
        }
        .agentsPane()
      }
    }

    @ViewBuilder private func projectThreads(_ row: ProjectRow, _ agents: AgentsService) -> some View {
      let group = groups[row.id]
      let rows = group?.threads ?? []
      if row.health == .missing {
        HStack(spacing: Space.s.points) {
          Text("Folder missing").foregroundStyle(.token(.attention))
          Spacer(minLength: 0)
          Button("Locate…") { Task { await actions.locate(row.id, agents) } }
            .controlSize(.small)
        }
        .textStyle(.caption)
        .listRowSeparator(.hidden)
        .selectionDisabled()
      }
      if rows.isEmpty, row.health != .missing {
        Text("No threads")
          .textStyle(.caption)
          .foregroundStyle(.secondary)
          .listRowSeparator(.hidden)
          .selectionDisabled()
      }
      ForEach(rows) { thread in
        ThreadRow(thread: thread, isWaiting: agents.waiting.contains(thread.id)).listRowSeparator(.hidden)
      }
      if let group, group.hidden > 0 {
        Button("Show \(min(group.hidden, AgentsService.threadsPerShowMore)) more") {
          shown[row.id] = group.threads.count + AgentsService.threadsPerShowMore
        }
        .appButton(.quiet, size: .small)
        .textStyle(.caption)
        .listRowSeparator(.hidden)
        .selectionDisabled()
      }
    }

    private func thread(_ id: AgentThread.ID?) -> ThreadSummary? {
      guard let id else { return nil }
      return groups.values.lazy.flatMap(\.threads).first { $0.id == id }
    }

    private func observeThreads() async {
      guard let agents else {
        groups = [:]
        selectedThread = nil
        return
      }
      do {
        for try await value in agents.threads(shown: shown, keeping: selectedThread) {
          if value != groups { groups = value }
          #if DEBUG
            if AgentsLaunch.listShown == nil {
              // The next main-queue turn runs after SwiftUI commits this update.
              await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
              let elapsed = ContinuousClock.now - createdAt
              AgentsLaunch.listShown = (
                Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                value.values.reduce(0) { $0 + $1.threads.count }
              )
            }
          #endif
          if thread(selectedThread) == nil {
            selectedThread = value.values.flatMap(\.threads).max { $0.lastActivityAt < $1.lastActivityAt }?.id
          }
        }
      } catch is CancellationError {
      } catch {
        groups = [:]
      }
    }
  }

  /// What the thread list query depends on; a change starts a new one.
  private struct ThreadQuery: Hashable {
    let ready: Bool
    let shown: [Project.ID: Int]
    let waiting: Set<AgentThread.ID>
    let selected: AgentThread.ID?
  }

  /// A project's group header in the thread list. Its actions sit in a menu button, which Tab
  /// reaches, and in the context menu and VoiceOver's actions on the header. The button stays in
  /// sight, because SwiftUI drops a view at opacity 0 from the accessibility tree.
  private struct ProjectHeader: View {
    let row: ProjectRow
    let actions: AgentsActions
    let agents: AgentsService

    var body: some View {
      HStack(spacing: Space.xs.points) {
        HStack(spacing: Space.xs.points) {
          Image(systemName: "folder")
          Text(row.project.name).lineLimit(1)
            .fontWeight(.semibold)
          if row.health == .missing { StatusIcon(.attention) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.project.name)
        .accessibilityValue(row.health == .missing ? "Folder missing" : "")
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions { menuItems }
        Spacer(minLength: 0)
        Menu {
          menuItems
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .appButton(.quiet, size: .small)
        .fixedSize()
        .accessibilityLabel("More for \(row.project.name)")
      }
      .textStyle(.caption)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
      .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
      Button("Rename…") { actions.beginRename(row) }
      Button("Locate…") { Task { await actions.locate(row.id, agents) } }
      Button("Show in Finder") { actions.showInFinder(row) }
        .disabled(row.health == .missing)
      Divider()
      Button("Remove from List") { Task { await actions.remove(row.id, agents) } }
    }
  }

  private struct ThreadRow: View {
    let thread: ThreadSummary
    let isWaiting: Bool

    /// Always two lines, so a thread that needs you is as tall as one that doesn't. Needs you takes
    /// the time's place in `attention`, which is the signal; nothing else on the row has hue.
    var body: some View {
      VStack(alignment: .leading, spacing: Space.xxs.points) {
        Text(thread.title).lineLimit(1)
        HStack(spacing: Space.xs.points) {
          Text(thread.provider == .claude ? "Claude" : "Codex")
          if isWaiting {
            Text("Needs you").foregroundStyle(.token(.attention))
          } else {
            Text(thread.lastActivityAt, format: .relative(presentation: .named))
          }
        }
        .textStyle(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      .padding(.vertical, Space.xs)
      .accessibilityElement(children: .combine)
    }
  }

  /// The traffic lights and the sidebar button, which take the band's left end once the sidebar
  /// collapses. The header's leading inset follows its distance from the window's edge, so the
  /// text moves aside with the sidebar as it slides instead of jumping when it ends.
  private let titlebarControlsWidth: CGFloat = 144

  /// A pane's header, in the toolbar band. Empty text keeps the band's height with nothing in it.
  private struct PaneHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let accessory: Accessory

    @State private var minX: CGFloat = .infinity

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(title).textStyle(.headline).lineLimit(1)
        if let subtitle {
          Text(subtitle).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .trailing) { accessory }
      .padding(.leading, max(Space.l.points, titlebarControlsWidth - minX))
      .padding(.trailing, Space.l)
      .onGeometryChange(for: CGFloat.self) {
        $0.frame(in: .global).minX
      } action: {
        minX = $0
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
    }
  }

  /// The selected thread's stored conversation, read-only until threads run.
  private struct ConversationPane: View {
    let agents: AgentsService
    let thread: AgentThread.ID?
    /// Live: a stored request with no outcome needs you only while its session is waiting on it.
    let isWaiting: Bool

    @State private var items: [ConversationItem] = []

    /// A chat column of about 46 em: lines stay readable however wide the window grows.
    static let readingWidth: CGFloat = 736

    var body: some View {
      Group {
        if thread == nil {
          ContentUnavailableView("No Thread Selected", systemImage: "bubble.left.and.text.bubble.right")
        } else {
          let pending = isWaiting ? items.pendingRequestIDs : []
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.m.points) {
              ForEach(items) { ItemRow(content: $0.content, pending: pending) }
            }
            .frame(maxWidth: Self.readingWidth, alignment: .leading)
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.l)
            .frame(maxWidth: .infinity)
          }
          .agentsPane()
        }
      }
      .task(id: thread) { await observe() }
    }

    private func observe() async {
      items = []
      guard let thread else { return }
      do {
        for try await rows in agents.conversation(thread) where rows != items {
          items = rows
        }
      } catch is CancellationError {
      } catch {
        items = []
      }
    }
  }

  private struct ItemRow: View {
    let content: ConversationItem.Content
    let pending: Set<String>

    var body: some View {
      switch content {
      case .userMessage(let text):
        Label {
          Text(text)
        } icon: {
          Image(systemName: "person")
        }
      case .assistantMessage(let text):
        Label {
          Text(text)
        } icon: {
          Image(systemName: "sparkle")
        }
      case .toolStep(let step):
        Label {
          Text(step.summary).foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "wrench.and.screwdriver")
        }
      case .request(let request):
        Label {
          VStack(alignment: .leading, spacing: Space.xxs.points) {
            Text("\(request.tool): \(request.summary)")
            if pending.contains(request.requestID) {
              Text("Needs you").textStyle(.caption).foregroundStyle(.token(.attention))
            }
          }
        } icon: {
          Image(systemName: "lock")
        }
      case .outcome(let outcome):
        Label {
          Text(Self.title(outcome.decision)).foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "checkmark.shield")
        }
      case .unsupported:
        EmptyView()
      }
    }

    private static func title(_ decision: RequestOutcome.Decision) -> String {
      switch decision {
      case .allowed: "Allowed"
      case .allowedAlways: "Always allowed"
      case .denied: "Denied"
      }
    }
  }

  extension View {
    /// Keeps a pane's list out of the toolbar band. A scroll view draws its own top edge effect
    /// under the toolbar and shows it while the pointer is over it, so two lists side by side split
    /// the band into two halves that change on hover. Clipped to its frame, which starts under the
    /// band, a list never scrolls into it, and the band stays one plain strip like Messages'.
    @ViewBuilder fileprivate func agentsPane() -> some View {
      if #available(macOS 26, *) {
        clipped().scrollEdgeEffectHidden(true, for: .top)
      } else {
        clipped()
      }
    }
  }
#endif
