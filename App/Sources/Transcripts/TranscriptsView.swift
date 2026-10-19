import AppKit
import DesignSystem
import DictationCore
import Storage
import SwiftUI
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts")

/// The newest transcripts first, loading more as the list scrolls. Selecting one
/// opens it in an inspector with its details; closing the inspector clears the selection.
/// New dictations appear without a reload.
struct TranscriptsView: View {
  let database: History.State
  let cache: ScreenCache
  let retry: () -> Void

  private enum Phase: Equatable {
    case loading
    case loaded(TranscriptPage)
    case failed
  }

  /// What the observation depends on; a change restarts it.
  private struct Query: Equatable {
    var database: ObjectIdentifier?
    var limit: Int
  }

  /// A load-more waiting for its grown page, for the TX-more signpost.
  private struct Growth {
    let limit: Int
    let since: ContinuousClock.Instant
  }

  /// What the TX-open, TX-more and TX-new signposts need between page commits. A class, so
  /// recording them does not redraw the list.
  private final class Signposts {
    let open = ScreenOpenReport()
    var growth: Growth?
    var newestShown: TranscriptItem.ID?
  }

  private static let detailMinWidth: CGFloat = 280
  private static let detailIdealWidth: CGFloat = 360
  private static let detailMaxWidth: CGFloat = 560

  @State private var phase: Phase
  @State private var limit = TranscriptPaging.pageSize
  @State private var selection: TranscriptItem.ID?
  @State private var showsDetail = false
  @State private var anchor = ViewAnchor()
  @State private var pendingDelete: TranscriptItem.ID?
  @State private var pageVersion = 0
  @State private var signposts = Signposts()
  @State private var hovered: TranscriptItem.ID?
  @State private var rowFrames = RowFrames()
  @State private var rowHeight: CGFloat?
  /// Opens on the newest transcripts it last showed, if any, so the first frame has the list.
  init(database: History.State, cache: ScreenCache, retry: @escaping () -> Void) {
    self.database = database
    self.cache = cache
    self.retry = retry
    let cached: TranscriptPage? =
      if case .ready(let db) = database { cache.newestPage(limit: TranscriptPaging.pageSize, in: db) } else {
        nil
      }
    _phase = State(initialValue: cached.map(Phase.loaded) ?? .loading)
  }

  var body: some View {
    content
      .background(AnchorView(anchor: anchor))
      .onChange(of: selection) { showDetail(selection != nil) }
      .navigationTitle("Transcripts")
      .task(id: query) { await observe() }
      .onChange(of: pageVersion) { reportShownAfterCommit() }
      .onAppear { if case .loaded = phase { pageVersion &+= 1 } }
      .confirmationDialog(
        "Delete this transcript?", isPresented: confirmingDelete, titleVisibility: .visible,
        presenting: pendingDelete
      ) { id in
        Button("Delete Transcript", role: .destructive) { delete(id) }
      } message: { _ in
        Text("This can't be undone.")
      }
  }

  private var query: Query {
    guard case .ready(let db) = database else { return Query(database: nil, limit: limit) }
    return Query(database: ObjectIdentifier(db), limit: limit)
  }

  private func observe() async {
    switch database {
    case .opening:
      phase = .loading
    case .failed:
      phase = .failed
    case .ready(let db):
      do {
        for try await page in db.transcripts(limit: limit) {
          if !signposts.open.isReported, case .loading = phase {
            ScreenSignposts.firstValue(screen: "tx", after: signposts.open.sinceOpened)
          }
          cache.store(page, in: db)
          AppIconCache.shared.warm(page.items.lazy.compactMap(\.bundleID))
          if phase != .loaded(page) {
            phase = .loaded(page)
            pageVersion &+= 1
          }
          await dropDeletedSelection(page, db)
        }
      } catch is CancellationError {
      } catch {
        phase = .failed
      }
    }
  }

  /// A selected row can leave the page because newer ones pushed it past the limit, so only a
  /// row that no longer exists, after an auto-delete or Delete All, clears the selection.
  private func dropDeletedSelection(_ page: TranscriptPage, _ db: AppDatabase) async {
    guard let id = selection, !page.items.contains(where: { $0.id == id }) else { return }
    do {
      if try await db.transcript(id: id) == nil, selection == id { selection = nil }
    } catch {
      logger.error("Checking the selected transcript failed: \(String(describing: error), privacy: .private)")
    }
  }

  private func loadMore() {
    #if DEBUG
      if TranscriptsHarness.driver.holdPages { return }
    #endif
    guard case .loaded(let page) = phase, page.hasMore, page.items.count >= limit else { return }
    limit += TranscriptPaging.pageSize
    signposts.growth = Growth(limit: limit, since: .now)
  }

  private func reportShownAfterCommit() { Task { reportShown() } }

  private func reportShown() {
    guard case .loaded(let page) = phase else { return }
    let now = ContinuousClock.now
    if signposts.open.markReported() {
      ScreenSignposts.transcriptsOpened(after: now - signposts.open.openedAt, rows: page.items.count)
    } else if let growth = signposts.growth, page.items.count >= growth.limit || !page.hasMore {
      signposts.growth = nil
      ScreenSignposts.transcriptsGrew(
        page: growth.limit / TranscriptPaging.pageSize - 1, after: now - growth.since, rows: page.items.count)
    }
    guard let top = page.items.first else { return }
    if let newestShown = signposts.newestShown, top.id > newestShown {
      ScreenSignposts.transcriptsNewRow(savedAt: top.createdAt, rows: page.items.count)
    }
    if top.id > signposts.newestShown ?? .min { signposts.newestShown = top.id }
  }

  /// The list carries no minimum width of its own: a minimum around it or the inspector made the
  /// inspector open in one frame and grew the window.
  @ViewBuilder private var content: some View {
    switch (phase, database) {
    case (.loaded(let page), .ready(let db)) where !page.items.isEmpty:
      list(page, db)
        .inspector(isPresented: inspecting) {
          TranscriptDetailPane(
            id: selection, database: db, close: closeDetail, delete: { pendingDelete = $0 }
          )
          .inspectorColumnWidth(
            min: Self.detailMinWidth, ideal: Self.detailIdealWidth, max: Self.detailMaxWidth)
        }
    default:
      state.frame(minWidth: MainWindow.detailMinWidth)
    }
  }

  @ViewBuilder private var state: some View {
    switch (phase, database) {
    case (.loaded(let page), .ready) where page.items.isEmpty:
      ContentUnavailableView(
        "No transcripts yet",
        systemImage: "text.bubble",
        description: Text("Start dictating to see your transcript history here."))
    case (.loading, _), (.loaded, _):
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case (.failed, _):
      ContentUnavailableView {
        Label("Could not load transcripts", systemImage: "exclamationmark.triangle")
      } description: {
        Text("Your transcripts are safe on this Mac. Try again.")
      } actions: {
        Button("Try Again", action: tryAgain).appButton()
      }
    }
  }

  /// The detail shows while a row is selected; closing it clears the selection.
  private var inspecting: Binding<Bool> {
    Binding(get: { showsDetail }, set: { if !$0 { selection = nil } })
  }

  /// Opens the detail after the window is wide enough for it. In a narrower window SwiftUI grew
  /// the window in uneven steps while the detail opened, and the list jumped to its top.
  private func showDetail(_ shows: Bool) {
    if shows, !showsDetail { widenForDetail() }
    showsDetail = shows
  }

  /// Grows the window, animated, until the screen is as wide as the other screens' minimum.
  private func widenForDetail() {
    guard let view = anchor.view, let window = view.window else { return }
    let missing = MainWindow.detailMinWidth - view.bounds.width
    guard missing > 0 else { return }
    var frame = window.frame
    frame.size.width += missing
    if let screen = window.screen?.visibleFrame {
      frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
    }
    window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }

  private var confirmingDelete: Binding<Bool> {
    Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
  }

  private func closeDetail() {
    selection = nil
  }

  private func delete(_ id: TranscriptItem.ID) {
    guard case .ready(let db) = database else { return }
    if selection == id { selection = nil }
    cache.removeAll()
    Task {
      do {
        try await db.deleteTranscript(id: id)
      } catch {
        logger.error("Deleting a transcript failed: \(String(describing: error), privacy: .private)")
      }
    }
  }

  private func tryAgain() {
    if case .failed = database {
      retry()
    } else {
      phase = .loading
      limit = TranscriptPaging.pageSize
      Task { await observe() }
    }
  }

  private func list(_ page: TranscriptPage, _ db: AppDatabase) -> some View {
    ScrollViewReader { proxy in
      rows(page, db)
        #if DEBUG
          .onChange(of: TranscriptsHarness.driver.scrollRequests) {
            if let last = page.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
          }
          .onChange(of: TranscriptsHarness.driver.revealRow) {
            if let index = TranscriptsHarness.driver.revealRow, page.items.indices.contains(index) {
              proxy.scrollTo(page.items[index].id, anchor: .center)
            }
          }
          .onChange(of: TranscriptsHarness.driver.selectRow) {
            if let index = TranscriptsHarness.driver.selectRow, page.items.indices.contains(index) {
              selection = page.items[index].id
            }
          }
        #endif
    }
  }

  private func rows(_ page: TranscriptPage, _ db: AppDatabase) -> some View {
    List(selection: $selection) {
      ForEach(page.items) { item in
        TranscriptRow(item: item, isActive: selection == item.id || hovered == item.id) {
          await TranscriptClipboard.copy(item.id, from: db)
        }
        .onAppear {
          if item.id == page.items.last?.id { loadMore() }
        }
        .onDisappear { rowFrames.remove(item.id) }
        // Only the row's vertical span: it stays put while the sidebar or the inspector resizes
        // the list, so those animations run no action per row per frame.
        .onGeometryChange(for: RowSpan.self) {
          RowSpan(frame: $0.frame(in: .global))
        } action: {
          rowFrames.set($0, for: item.id)
          if rowHeight != $0.height { rowHeight = $0.height }
        }
        .zeroVerticalRowInsets()
      }
      if page.hasMore {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      }
    }
    // SwiftUI's only control over the row height a macOS list gives an inserted row for its first
    // frame. At the system default, a new dictation showed one line tall with the separator through
    // its text.
    .transformEnvironment(\.defaultMinListRowHeight) { if let rowHeight { $0 = rowHeight } }
    .contextMenu(forSelectionType: TranscriptItem.ID.self) { ids in
      if let id = ids.first {
        Button("Copy Transcript", systemImage: "doc.on.doc") {
          Task { await TranscriptClipboard.copy(id, from: db) }
        }
        Divider()
        Button("Delete Transcript…", systemImage: "trash", role: .destructive) { pendingDelete = id }
      }
    }
    .onCopyCommand(perform: selection.map { id in { [TranscriptClipboard.provider(id, from: db)] } })
    .onDeleteCommand {
      if let selection { pendingDelete = selection }
    }
    .onExitCommand(perform: closeDetail)
    // One hover region for the whole list: a region on every row made AppKit move its tracking
    // areas on every scrolled frame, which cost about a third of the frames.
    .onContinuousHover(coordinateSpace: .global) { phase in
      switch phase {
      case .active(let point): hovered = rowFrames.row(at: point)
      case .ended: hovered = nil
      }
    }
    .onScrollPhaseChange { _, phase in
      if phase != .idle { hovered = nil }
    }
    #if DEBUG
      .onChange(of: TranscriptsHarness.driver.inspectRequests) {
        selection = selection == nil ? page.items.first?.id : nil
      }
    #endif
  }
}

/// A row's top and bottom in global coordinates. The hover region covers only the list, so the
/// pointer's height alone names the row under it.
nonisolated private struct RowSpan: Equatable {
  let top: CGFloat
  let bottom: CGFloat

  init(frame: CGRect) {
    top = frame.minY
    bottom = frame.maxY
  }

  var height: CGFloat { bottom - top }

  func contains(_ y: CGFloat) -> Bool { y >= top && y < bottom }
}

/// Where the visible rows are, for the list's one hover region. Not observed: rows write it on
/// every scrolled frame, and only a pointer move reads it.
private final class RowFrames {
  private var spans: [TranscriptItem.ID: RowSpan] = [:]

  func set(_ span: RowSpan, for id: TranscriptItem.ID) { spans[id] = span }
  func remove(_ id: TranscriptItem.ID) { spans[id] = nil }
  func row(at point: CGPoint) -> TranscriptItem.ID? {
    spans.first { $0.value.contains(point.y) }?.key
  }
}

/// The AppKit view behind the Transcripts screen, for its window and width.
private final class ViewAnchor {
  weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
  let anchor: ViewAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
  /// Rows sit flush so the hover spans tile the list. Before macOS 26 a list can only replace
  /// all four insets, so rows keep the system's.
  @ViewBuilder fileprivate func zeroVerticalRowInsets() -> some View {
    if #available(macOS 26, *) {
      listRowInsets(.vertical, 0)
    } else {
      self
    }
  }
}
