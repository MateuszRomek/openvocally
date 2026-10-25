import AppKit
import Observation
import SwiftUI

/// Key only while the thread panel is open, so the closed notch never takes focus from the app
/// you are typing in. Never main, so the frontmost app stays active either way.
final class NotchPanel: NSPanel {
  var acceptsKey = false
  override var canBecomeKey: Bool { acceptsKey }
  override var canBecomeMain: Bool { false }
}

/// A click on the closed notch must land on the first press, without first activating the lab.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@Observable final class DisplayState {
  var screen: NSScreen
  var metrics: NotchMetrics
  /// The drawn shape in the panel's flipped coordinates. Read for hit-testing, never drawn.
  @ObservationIgnored var shapeRect: CGRect = .zero

  init(screen: NSScreen, metrics: NotchMetrics) {
    self.screen = screen
    self.metrics = metrics
  }
}

/// One fixed panel per display. Only the shape inside it animates; the window frame never moves.
final class DisplayHost {
  /// Wide enough for the large thread size; as tall as the display allows.
  static func canvas(for screen: NSScreen) -> CGSize {
    CGSize(width: 960, height: min(1000, screen.frame.height))
  }

  let state: DisplayState
  let panel: NotchPanel

  init(screen: NSScreen, lab: Lab) {
    state = DisplayState(
      screen: screen,
      metrics: .of(screen, forceNotchless: lab.forceNotchless, simulated: lab.simulatedHeight))
    panel = NotchPanel(
      contentRect: NSRect(origin: .zero, size: Self.canvas(for: screen)),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let hosting = FirstMouseHostingView(rootView: NotchRoot(lab: lab, display: state))
    hosting.sizingOptions = []
    panel.contentView = hosting
    place()
  }

  func refresh(lab: Lab) {
    state.metrics = .of(state.screen, forceNotchless: lab.forceNotchless, simulated: lab.simulatedHeight)
    place()
  }

  private func place() {
    let size = Self.canvas(for: state.screen)
    let origin = NSPoint(
      x: state.metrics.centerX - size.width / 2, y: state.screen.frame.maxY - size.height)
    panel.setFrame(NSRect(origin: origin, size: size), display: false)
    panel.orderFrontRegardless()
  }

  /// The drawn shape in global screen coordinates, reaching the top edge so a flick to the top
  /// of the screen lands on it. Clicks land only here.
  var clickRect: CGRect {
    let r = state.shapeRect
    guard r.width > 0 else { return .zero }
    let frame = CGRect(
      x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    return CGRect(
      x: frame.minX, y: frame.minY, width: frame.width, height: state.screen.frame.maxY - frame.minY)
  }

  /// Where the pointer starts the hover dwell: the shape grown sideways and `reach` below it.
  /// Hover only, so the deeper zone never swallows a click on the tab bar under it.
  func hoverRect(reach: CGFloat) -> CGRect {
    let r = clickRect
    guard r.width > 0 else { return .zero }
    return CGRect(x: r.minX - 12, y: r.minY - reach, width: r.width + 24, height: r.height + reach)
  }

  func setKey(_ key: Bool) {
    panel.acceptsKey = key
    if key {
      panel.makeKeyAndOrderFront(nil)
    } else if panel.isKeyWindow {
      // Ordering the key panel out hands the keyboard back to the frontmost app's window.
      panel.orderOut(nil)
      panel.orderFrontRegardless()
    }
  }
}

/// Owns the panels and the pointer: hover to peek or open, click outside to close.
final class Stage {
  private let lab: Lab
  private var hosts: [ScreenID: DisplayHost] = [:]
  private var monitors: [Any] = []
  private var dwell: Task<Void, Never>?
  private var leave: Task<Void, Never>?

  init(lab: Lab) {
    self.lab = lab
    rebuild()
    lab.onLayoutChange = { [weak self] in self?.refresh() }
    lab.onOpenChange = { [weak self] screen, level in
      guard let self else { return }
      for (id, host) in hosts { host.setKey(!lab.passive && id == screen && level == .expanded) }
    }
    let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: moved) { [weak self] _ in
        MainActor.assumeIsolated { self?.pointerMoved() }
      } as Any)
    monitors.append(
      NSEvent.addLocalMonitorForEvents(matching: moved) { [weak self] event in
        self?.pointerMoved()
        return event
      } as Any)
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
        MainActor.assumeIsolated { self?.clickedOutside() }
      } as Any)
  }

  func rebuild() {
    for host in hosts.values { host.panel.orderOut(nil) }
    hosts = Dictionary(
      NSScreen.screens.map { ($0.screenID, DisplayHost(screen: $0, lab: lab)) },
      uniquingKeysWith: { first, _ in first })
  }

  func refresh() {
    for host in hosts.values { host.refresh(lab: lab) }
  }

  var displaySummary: String {
    NSScreen.screens.map { screen in
      let metrics = hosts[screen.screenID]?.state.metrics
      let kind = metrics?.isReal == true ? "notch" : "no notch"
      let size = metrics.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "?"
      let menuBar = screen.hasMenuBar ? "menu bar \(Int(screen.menuBarHeight)) pt" : "no menu bar"
      return "\(screen.localizedName): \(kind), \(size) pt, \(menuBar)"
    }.joined(separator: "\n")
  }

  private func pointerMoved() {
    let point = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    if lab.pointerScreen != screen?.screenID { lab.pointerScreen = screen?.screenID }

    var inside: ScreenID?
    for (id, host) in hosts {
      let clickable = host.clickRect.contains(point)
      if host.panel.ignoresMouseEvents == clickable { host.panel.ignoresMouseEvents = !clickable }
      if host.hoverRect(reach: lab.hoverReach.points).contains(point) { inside = id }
    }

    if let inside {
      leave?.cancel()
      leave = nil
      let level = hosts[inside].map { lab.level(on: $0.state.screen) } ?? .idle
      guard dwell == nil, level == .idle || level == .status, lab.hover != .none else { return }
      dwell = Task { [weak self, lab] in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        self?.dwell = nil
        lab.open(lab.hover == .open ? .expanded : .peek, on: inside)
      }
    } else {
      dwell?.cancel()
      dwell = nil
      let closes = lab.openLevel == .peek || (lab.openLevel == .expanded && lab.close == .mouseExit)
      guard closes, leave == nil else { return }
      leave = Task { [weak self, lab] in
        try? await Task.sleep(for: .milliseconds(lab.openLevel == .peek ? 150 : 400))
        guard !Task.isCancelled else { return }
        self?.leave = nil
        lab.closeAll()
      }
    }
  }

  private func clickedOutside() {
    // Global monitors only see clicks in other apps, so every click here is outside the panel.
    if lab.openLevel == .expanded { lab.closeAll() }
  }
}
