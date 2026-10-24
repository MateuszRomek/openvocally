import AppKit
import DesignSystem
import SwiftUI
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "overlay")

/// One fixed `OverlayMetrics.canvas` panel per display. The window never moves or resizes
/// while shown; only the island inside it animates.
@MainActor public final class OverlayHost {
  private var slots: [OverlaySource: OverlayActivity] = [:]
  private var panels: [CGDirectDisplayID: ScreenPanel] = [:]
  private var active: CGDirectDisplayID?
  private let bars = BarsModel()
  private var meterIsLive = false
  /// Bumped by every change, so a superseded animation's completion cannot cut a later hide.
  private var generation = 0
  private var observers: [any NSObjectProtocol] = []
  /// Exists only while a scene is shown, so the idle app runs no timer.
  private var follow: Task<Void, Never>?
  private var check: Task<Void, Never>?
  /// Every finished `show` animation, superseded ones included, so a test can wait for a
  /// completion instead of a fixed time.
  private(set) var finishedAnimations = 0
  /// Read on each appearance, so a change in Settings applies without a restart.
  private let preference: @MainActor () -> OverlayPreference
  /// The cursor in global screen points, swappable so a Debug harness can aim at a display
  /// without moving the real cursor.
  private let pointer: @MainActor () -> CGPoint

  public init(
    preference: @escaping @MainActor () -> OverlayPreference = { .stored() },
    pointer: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }
  ) {
    self.preference = preference
    self.pointer = pointer
  }

  /// Builds a panel for every display and draws a recording frame into each while
  /// invisible, so the first press pays for neither the backing store nor the text and
  /// symbol caches.
  public func prewarm() {
    observeScreens()
    rebuild()
  }

  /// Synchronous: on return the new scene is laid out and drawn into the panel, so only the
  /// compositor's next frame remains (LB-01). The same activity again does nothing.
  public func show(_ activity: OverlayActivity?, from source: OverlaySource) {
    var next = slots
    next[source] = activity
    guard next != slots else { return }
    // Before the slots change, so a first show without `prewarm` still animates and announces.
    if panels.isEmpty { rebuild() }
    announceIfNewAlert(activity, replacing: slots[source])
    slots = next
    let scene = OverlayScene(next)
    let old = activePanel?.model.scene ?? .hidden
    let live = Self.showsLiveMeter(scene)
    // A new meter starts flat instead of showing the previous session's last levels.
    if live, !meterIsLive { bars.bands = [] }
    meterIsLive = live
    if old.level == .hidden, scene.level != .hidden { present() }
    if scene.level == .hidden {
      if old.level != .hidden { logger.notice("Overlay hidden") }
      stopFollowing()
    }
    guard let panel = activePanel else { return }
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let animation: Animation? =
      reduce && old.level == .hidden
      ? nil : OverlayScene.motion(from: old, to: scene).resolved(reduceMotion: reduce)
    generation += 1
    let current = generation
    withAnimation(animation, completionCriteria: .removed) {
      panel.model.scene = scene
    } completion: { [weak self] in
      guard let self else { return }
      self.finishedAnimations += 1
      guard self.generation == current else { return }
      self.orderOutHidden()
    }
    panel.draw()
  }

  /// Writes the bars model only, and only while the island shows the live meter, so a stray
  /// tick after release costs nothing.
  public func meter(_ bands: [Float]) {
    guard meterIsLive else { return }
    bars.bands = bands
  }

  private static func showsLiveMeter(_ scene: OverlayScene) -> Bool {
    guard case .compact(.bars(.live)) = scene.primary?.body else { return false }
    return true
  }

  private var activePanel: ScreenPanel? { active.flatMap { panels[$0] } }

  /// The panel never takes focus, so VoiceOver would miss an alert unless it is announced.
  /// Compared per source, so another source covering the alert and clearing does not repeat it.
  private func announceIfNewAlert(_ activity: OverlayActivity?, replacing old: OverlayActivity?) {
    guard let activity, activity.level == .alert, activity.accessibilityLabel != old?.accessibilityLabel
    else { return }
    let label = activity.accessibilityLabel
    NSAccessibility.post(
      element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [
        .announcement: label,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  private func present() {
    let screens = Self.screens()
    let found = Self.display(
      containing: pointer(), in: screens.map { (id: $0.id, frame: $0.screen.frame) })
    let target =
      screens.first { $0.id == found }
      ?? screens.first { $0.screen == NSScreen.main } ?? screens.first
    guard let target else {
      logger.notice("Overlay skipped: no display")
      return
    }
    guard var panel = panels[target.id] else {
      logger.notice("Overlay skipped: no panel for display \(target.id, privacy: .public)")
      return
    }
    if let active, active != target.id { panels[active]?.panel.orderOut(nil) }
    active = target.id
    panel.place(on: target.screen, preference: preference())
    panel.panel.orderFrontRegardless()
    if !panel.panel.isOnActiveSpace {
      panel = replacePanel(target.id, on: target.screen)
    }
    logger.notice("Overlay shown on display \(target.id, privacy: .public)")
    checkVisible(on: target.id)
    startFollowing()
  }

  /// When a full-screen Space closes while a panel is ordered out, the window server drops the
  /// panel from every other full-screen Space despite `canJoinAllSpaces`, and resetting
  /// `collectionBehavior` does not bring it back. A new window joins them all again. Costs one
  /// unwarmed first draw, on a press that would otherwise show nothing.
  private func replacePanel(_ id: CGDirectDisplayID, on screen: NSScreen) -> ScreenPanel {
    logger.error("Overlay panel off the active Space on display \(id, privacy: .public), replacing it")
    panels[id]?.panel.orderOut(nil)
    let panel = ScreenPanel(bars: bars)
    panels[id] = panel
    panel.place(on: screen, preference: preference())
    panel.panel.orderFrontRegardless()
    return panel
  }

  /// The display whose frame holds `point`. Edges follow `NSMouseInRect` for unflipped
  /// coordinates (min x and max y inside), so a point on a shared edge has one owner.
  static func display(
    containing point: CGPoint, in displays: [(id: CGDirectDisplayID, frame: CGRect)]
  ) -> CGDirectDisplayID? {
    displays.first { contains(point, $0.frame) }?.id
  }

  private static func contains(_ point: CGPoint, _ frame: CGRect) -> Bool {
    point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
  }

  private func startFollowing() {
    guard follow == nil else { return }
    follow = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        self?.followCursor()
      }
    }
  }

  private func stopFollowing() {
    follow?.cancel()
    follow = nil
    check?.cancel()
    check = nil
  }

  /// A shown overlay the user cannot see leaves no trace in the log on its own. Once the island
  /// has had time to appear, this records what the window server reports for the panel, and
  /// the display of the cursor and of the focused window, so a diagnostics file can tell a
  /// panel that never reached the screen from one shown away from where the user looked.
  private func checkVisible(on id: CGDirectDisplayID) {
    check?.cancel()
    check = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, let self, self.active == id, let panel = self.panels[id]?.panel
      else { return }
      let screens = Self.screens()
      let frames = screens.map { (id: $0.id, frame: $0.screen.frame) }
      let panelDisplay = Self.display(
        containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY), in: frames)
      let cursorDisplay = Self.display(containing: self.pointer(), in: frames)
      let focusDisplay = Self.focusedWindowCentre().flatMap { Self.display(containing: $0, in: frames) }
      logger.notice(
        """
        Overlay check on display \(id, privacy: .public): visible \(panel.isVisible, privacy: .public), \
        unoccluded \(panel.occlusionState.contains(.visible), privacy: .public), \
        on active Space \(panel.isOnActiveSpace, privacy: .public), \
        panel display \(panelDisplay.map(String.init) ?? "none", privacy: .public), \
        cursor display \(cursorDisplay.map(String.init) ?? "none", privacy: .public), \
        focused window display \(focusDisplay.map(String.init) ?? "none", privacy: .public)
        """)
    }
  }

  /// The centre of the frontmost app's front window, in global screen points. Skips the
  /// transparent strip a full-screen window keeps above itself.
  private static func focusedWindowCentre() -> CGPoint? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let primary = NSScreen.screens.first
    else { return nil }
    let front = windows.first {
      ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }
    guard let bounds = front?[kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: bounds)
    else { return nil }
    return CGPoint(x: rect.midX, y: primary.frame.maxY - rect.midY)
  }

  private func followCursor() {
    guard let from = active else { return }
    let screens = Self.screens()
    guard
      let to = Self.display(
        containing: pointer(), in: screens.map { (id: $0.id, frame: $0.screen.frame) }),
      to != from, let screen = screens.first(where: { $0.id == to })?.screen
    else { return }
    handOff(from: from, to: to, on: screen)
  }

  private func handOff(from: CGDirectDisplayID, to: CGDirectDisplayID, on screen: NSScreen) {
    let scene = OverlayScene(slots)
    guard scene.level != .hidden, let panel = panels[to] else { return }
    let old = panels[from]
    logger.notice("Overlay moved to display \(to, privacy: .public)")
    checkVisible(on: to)
    active = to
    generation += 1
    panel.model.scene = .hidden
    panel.place(on: screen, preference: preference())
    panel.draw()
    panel.panel.orderFrontRegardless()
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard !reduce else {
      panel.model.scene = scene
      panel.draw()
      old?.model.scene = .hidden
      old?.panel.orderOut(nil)
      return
    }
    withAnimation(OverlayScene.motion(from: .hidden, to: scene).resolved(reduceMotion: false)) {
      panel.model.scene = scene
    }
    panel.draw()
    guard let old else { return }
    withAnimation(
      OverlayScene.motion(from: scene, to: .hidden).resolved(reduceMotion: false),
      completionCriteria: .removed
    ) {
      old.model.scene = .hidden
    } completion: { [weak self] in
      // The cursor may have come back while the old island was leaving.
      guard let self, self.active != from else { return }
      old.panel.orderOut(nil)
    }
  }

  private func orderOutHidden() {
    let hidden = OverlayScene(slots).level == .hidden
    for (id, panel) in panels where hidden || id != active {
      panel.panel.orderOut(nil)
    }
  }

  /// Idempotent: keeps panels whose display still exists, drops the rest and prewarms new
  /// ones. A visible scene moves to the cursor display when its display is gone.
  private func rebuild() {
    let screens = Self.screens()
    let ids = Set(screens.map(\.id))
    for (id, panel) in panels where !ids.contains(id) {
      panel.panel.orderOut(nil)
      panels[id] = nil
    }
    for screen in screens where panels[screen.id] == nil {
      let panel = ScreenPanel(bars: bars)
      panel.prewarm(on: screen.screen, preference: preference())
      panels[screen.id] = panel
    }
    let scene = OverlayScene(slots)
    guard scene.level != .hidden else { return }
    if let active, let panel = panels[active], let screen = screens.first(where: { $0.id == active }) {
      panel.place(on: screen.screen, preference: panel.preference)
      panel.draw()
      return
    }
    active = nil
    present()
    guard let panel = activePanel else { return }
    panel.model.scene = scene
    panel.draw()
  }

  private func observeScreens() {
    guard observers.isEmpty else { return }
    let handler: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.rebuild() }
    }
    observers = [
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
        using: handler),
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler),
    ]
  }

  private static func screens() -> [(id: CGDirectDisplayID, screen: NSScreen)] {
    NSScreen.screens.compactMap { screen in
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      return number.map { (id: $0.uint32Value, screen: screen) }
    }
  }

  var visiblePanel: NSPanel? {
    activePanel.flatMap { $0.panel.isVisible ? $0.panel : nil }
  }
}

/// Never key and never main, so the overlay cannot take focus from the paste target.
private final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// The notch canvas covers the menu bar, where AppKit would otherwise push a window down.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

@MainActor private final class ScreenPanel {
  let panel: NSPanel
  let hosting: NSHostingView<OverlayRoot>
  let model = SceneModel()

  /// Click-through, never takes focus, above full-screen apps, on every Space.
  init(bars: BarsModel) {
    let panel = NonActivatingPanel(
      contentRect: NSRect(origin: .zero, size: OverlayMetrics.canvas),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let hosting = NSHostingView(rootView: OverlayRoot(model: model, bars: bars))
    hosting.sizingOptions = []
    panel.contentView = hosting
    self.panel = panel
    self.hosting = hosting
  }

  private(set) var preference = OverlayPreference(style: .fallback, edge: .fallback)

  func place(on screen: NSScreen, preference: OverlayPreference) {
    let geometry = ScreenGeometry(screen)
    let placement = preference.placement(on: geometry)
    self.preference = preference
    panel.setFrame(placement.panelFrame(on: geometry), display: false)
    guard placement != model.placement else { return }
    model.placement = placement
    // Drawn now, so the first frame after a style or display change is not the old stage.
    draw()
  }

  /// Every placement this display can show, so a first press after switching style in Settings
  /// is warm too.
  func prewarm(on screen: NSScreen, preference stored: OverlayPreference) {
    let geometry = ScreenGeometry(screen)
    var warmed: [OverlayPlacement] = []
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    for style in OverlayStyle.allCases {
      let preference = OverlayPreference(style: style, edge: stored.edge)
      guard !warmed.contains(preference.placement(on: geometry)) else { continue }
      warmed.append(preference.placement(on: geometry))
      place(on: screen, preference: preference)
      model.scene = OverlayScene(primary: OverlayRoot.warmFrame)
      draw()
      model.scene = .hidden
      draw()
    }
    place(on: screen, preference: stored)
    panel.orderOut(nil)
    panel.alphaValue = 1
  }

  func draw() {
    hosting.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
  }
}

@MainActor @Observable final class SceneModel {
  var scene = OverlayScene.hidden
  var placement = OverlayPlacement.island(.fallback)
}

/// Read only by `BarsView`, so a meter tick re-evaluates nothing else.
@MainActor @Observable final class BarsModel {
  var bands: [Float]

  init(bands: [Float] = []) {
    self.bands = bands
  }
}
