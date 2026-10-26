import AppKit
import DictationCore
import OverlayCore
import SwiftUI
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "overlay")

/// The dictation notch: one `NotchCore` and one fixed panel per display. The core decides every
/// scene and how it moves; this host only delivers events and draws the frames it returns.
@MainActor public final class NotchHost {
  private var core = NotchCore()
  private var panels: [CGDirectDisplayID: NotchPanel] = [:]
  private let bars = BarsModel()
  private var meterIsLive = false
  /// The display showing a visible scene, nil while hidden.
  private var shownOn: CGDirectDisplayID?
  private var announced: String?
  private var observers: [any NSObjectProtocol] = []
  /// Exist only while something waits on time or the scene is visible, so the idle app runs no
  /// timer.
  private var tick: Task<Void, Never>?
  private var follow: Task<Void, Never>?
  private var check: Task<Void, Never>?
  /// The cursor in global screen points, swappable so a Debug harness can aim at a display
  /// without moving the real cursor.
  private let pointer: @MainActor () -> CGPoint
  private let reduceMotion: Bool?
  private let appearance: NSAppearance.Name?
  private let separateSpaces: Bool?

  /// `reduceMotion` forces the Reduce Motion variant on or off; nil follows the system.
  /// `appearance` forces the panels' appearance, such as Increase Contrast; nil follows the app.
  /// `separateSpaces` forces whether every display has a menu bar; nil follows the system.
  public init(
    pointer: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }, reduceMotion: Bool? = nil,
    appearance: NSAppearance.Name? = nil, separateSpaces: Bool? = nil
  ) {
    self.pointer = pointer
    self.reduceMotion = reduceMotion
    self.appearance = appearance
    self.separateSpaces = separateSpaces
  }

  /// The display showing a visible scene and its panel's window number, for a Debug harness
  /// that captures that window alone.
  public var shownPanel: (display: CGDirectDisplayID, window: Int)? {
    guard let shownOn, let panel = panels[shownOn] else { return nil }
    return (shownOn, panel.panel.windowNumber)
  }

  /// Builds a panel for every display and draws a recording frame into each while invisible,
  /// so the first press pays for neither the backing store nor the text and symbol caches.
  public func prewarm() {
    observeScreens()
    rebuild()
  }

  /// Synchronous: on return the new frame is laid out and drawn into the panel, so only the
  /// compositor's next frame remains (LB-01).
  public func show(_ phase: DictationPhase) {
    if panels.isEmpty { rebuild() }
    if let display = pointerDisplay(), display != core.pointerDisplay?.rawValue {
      send(.pointer(movedOnto: DisplayID(rawValue: display)))
    }
    send(.dictation(phase))
  }

  /// Writes the bars model only, and only while the notch shows the live meter, so a stray tick
  /// after release costs nothing.
  public func meter(_ bands: [Float]) {
    guard meterIsLive else { return }
    bars.bands = bands
  }

  private func send(_ event: NotchEvent) {
    let outcome = core.send(event, at: .now())
    let live = core.scene.strip == .voice(.recording)
    if live, !meterIsLive { bars.bands = [] }
    meterIsLive = live
    let now = Date.now
    let hostNow = HostTime.now()
    for (display, frame) in outcome.frames {
      guard let panel = panels[display.rawValue] else {
        logger.notice("Overlay skipped: no panel for display \(display.rawValue, privacy: .public)")
        continue
      }
      panel.model.drawing = NotchDrawing(frame, now: now, hostNow: hostNow)
      panel.draw()
    }
    if !outcome.frames.isEmpty { announceIfNewNotice() }
    track()
    scheduleTick()
  }

  private func track() {
    if core.scene == .hidden { stopFollowing() } else { startFollowing() }
    let visible = core.scene == .hidden ? nil : core.activeDisplay?.rawValue
    guard visible != shownOn else { return }
    let old = shownOn
    shownOn = visible
    switch (old, visible) {
    case (nil, let to?):
      logger.notice("Overlay shown on display \(to, privacy: .public)")
      checkVisible(on: to)
    case (_?, let to?):
      logger.notice("Overlay moved to display \(to, privacy: .public)")
      checkVisible(on: to)
    case (_?, nil):
      logger.notice("Overlay hidden")
      check?.cancel()
      check = nil
    case (nil, nil):
      break
    }
  }

  private func scheduleTick() {
    tick?.cancel()
    tick = nil
    guard let deadline = core.nextDeadline else { return }
    let delay = max(.zero, deadline.duration(since: .now()))
    tick = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.send(.tick)
    }
  }

  /// The panel never takes focus, so VoiceOver would miss a notice unless it is announced.
  private func announceIfNewNotice() {
    guard case .notice(let notice)? = core.scene.strip,
      let label = OverlayActivity(lead: .notice(notice))?.accessibilityLabel
    else {
      announced = nil
      return
    }
    guard label != announced else { return }
    announced = label
    NSAccessibility.post(
      element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [
        .announcement: label,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  /// The display under the pointer, else the main display, else the first.
  private func pointerDisplay() -> CGDirectDisplayID? {
    let screens = Self.screens()
    let found = OverlayHost.display(
      containing: pointer(), in: screens.map { (id: $0.id, frame: $0.screen.frame) })
    let target =
      screens.first { $0.id == found }
      ?? screens.first { $0.screen == NSScreen.main } ?? screens.first
    if target == nil { logger.notice("Overlay skipped: no display") }
    return target?.id
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

  private func followCursor() {
    let screens = Self.screens()
    guard
      let to = OverlayHost.display(
        containing: pointer(), in: screens.map { (id: $0.id, frame: $0.screen.frame) }),
      to != core.pointerDisplay?.rawValue
    else { return }
    send(.pointer(movedOnto: DisplayID(rawValue: to)))
  }

  /// A shown notch the user cannot see leaves no trace in the log on its own. Once the scene has
  /// had time to appear, this records what the window server reports for the panel, and the
  /// display of the cursor and of the focused window.
  private func checkVisible(on id: CGDirectDisplayID) {
    check?.cancel()
    check = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, let self, self.shownOn == id, let notchPanel = self.panels[id]
      else { return }
      let panel = notchPanel.panel
      let frames = Self.screens().map { (id: $0.id, frame: $0.screen.frame) }
      let panelDisplay = OverlayHost.display(
        containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY), in: frames)
      let cursorDisplay = OverlayHost.display(containing: self.pointer(), in: frames)
      let focusDisplay = OverlayHost.focusedWindowCentre().flatMap {
        OverlayHost.display(containing: $0, in: frames)
      }
      logger.notice(
        """
        Overlay check on display \(id, privacy: .public): visible \(notchPanel.isShown, privacy: .public), \
        unoccluded \(panel.occlusionState.contains(.visible), privacy: .public), \
        on active Space \(panel.isOnActiveSpace, privacy: .public), \
        panel display \(panelDisplay.map(String.init) ?? "none", privacy: .public), \
        cursor display \(cursorDisplay.map(String.init) ?? "none", privacy: .public), \
        focused window display \(focusDisplay.map(String.init) ?? "none", privacy: .public)
        """)
    }
  }

  /// Idempotent: keeps panels whose display still exists, drops the rest and prewarms new ones.
  /// A display that disappears takes its frame with it; the pointer poll moves the scene on.
  private func rebuild() {
    let screens = Self.screens()
    // A display's own menu bar is the gap above its visible frame. An auto-hidden menu bar leaves
    // no gap, so the main menu's height stands in; `NSStatusBar.system.thickness` reports 22
    // where the menu bar is 30.
    let reported = NSApp.mainMenu?.menuBarHeight ?? 0
    let fallback = reported > 0 ? reported : OverlayMetrics.notchSimulated.height
    func menuBarHeight(_ screen: NSScreen) -> CGFloat {
      let gap = screen.frame.maxY - screen.visibleFrame.maxY
      return gap > 0 ? gap : fallback
    }
    let ids = Set(screens.map(\.id))
    for (id, panel) in panels where !ids.contains(id) {
      panel.panel.orderOut(nil)
      panels[id] = nil
    }
    for screen in screens {
      if let panel = panels[screen.id] {
        panel.place(on: screen.screen, menuBarHeight: menuBarHeight(screen.screen))
      } else {
        let panel = NotchPanel(
          bars: bars, reduceMotion: reduceMotion, screen: screen.screen,
          menuBarHeight: menuBarHeight(screen.screen))
        panel.panel.appearance = appearance.flatMap(NSAppearance.init(named:))
        panel.prewarm()
        panels[screen.id] = panel
      }
    }
    // Without separate Spaces only the primary display, the first screen, has a menu bar.
    let withMenuBar =
      (separateSpaces ?? NSScreen.screensHaveSeparateSpaces) ? screens : Array(screens.prefix(1))
    send(.displays(withMenuBar: Set(withMenuBar.map { DisplayID(rawValue: $0.id) })))
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
}

@MainActor private final class NotchPanel {
  let panel: NSPanel
  let hosting: NSHostingView<NotchRoot>
  let model: NotchPanelModel

  init(bars: BarsModel, reduceMotion: Bool?, screen: NSScreen, menuBarHeight: CGFloat) {
    let panel = NonActivatingPanel.overlay(size: OverlayMetrics.canvas)
    model = NotchPanelModel(placement: NotchPlacement(screen, menuBarHeight: menuBarHeight))
    let hosting = NSHostingView(rootView: NotchRoot(model: model, bars: bars, reduceMotion: reduceMotion))
    hosting.sizingOptions = []
    panel.contentView = hosting
    self.panel = panel
    self.hosting = hosting
    panel.setFrame(model.placement.panelFrame(on: screen.frame), display: false)
  }

  func place(on screen: NSScreen, menuBarHeight: CGFloat) {
    let placement = NotchPlacement(screen, menuBarHeight: menuBarHeight)
    panel.setFrame(placement.panelFrame(on: screen.frame), display: false)
    guard placement != model.placement else { return }
    model.placement = placement
    draw()
  }

  /// Draws a recording frame at alpha 0, then the hidden scene, which shows nothing. The panel
  /// then stays ordered in at alpha 1: there is no animation completion to hide it after, and
  /// ordering out strands it off full-screen Spaces (see `ScreenPanel.hide()`).
  func prewarm() {
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    model.drawing = .after([.recording(.pushToTalk)])
    draw()
    model.drawing = .hidden
    draw()
    panel.alphaValue = 1
  }

  var isShown: Bool { panel.isVisible && panel.alphaValue > 0 && model.drawing.scene != .hidden }

  func draw() {
    hosting.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
  }
}

@MainActor @Observable private final class NotchPanelModel {
  var drawing = NotchDrawing.hidden
  var placement: NotchPlacement

  init(placement: NotchPlacement) {
    self.placement = placement
  }
}

/// The hosting root, created once per panel and never replaced.
private struct NotchRoot: View {
  let model: NotchPanelModel
  let bars: BarsModel
  let reduceMotion: Bool?

  var body: some View {
    NotchFrameView(drawing: model.drawing, placement: model.placement)
      .frame(width: OverlayMetrics.canvas.width, height: OverlayMetrics.canvas.height, alignment: .top)
      // A panel that draws no pixels reports itself occluded when the notch appears, and the
      // entry spring then never shows: the notch pops in at full size.
      .background(alignment: .bottomLeading) {
        Color.black  // allowed: invisible pixel
          .opacity(OverlayMetrics.occlusionAnchorOpacity)
          .frame(width: 1, height: 1)
      }
      .environment(bars)
      .environment(\.reduceMotionOverride, reduceMotion)
  }
}
