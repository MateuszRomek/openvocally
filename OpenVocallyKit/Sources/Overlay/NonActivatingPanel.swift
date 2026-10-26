import AppKit

/// Never key and never main, so the overlay cannot take focus from the paste target.
final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// The notch canvas covers the menu bar, where AppKit would otherwise push a window down.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  /// Click-through, never takes focus, above full-screen apps, on every Space. Configured like
  /// the pill's panel.
  static func overlay(size: CGSize) -> NonActivatingPanel {
    let panel = NonActivatingPanel(
      contentRect: NSRect(origin: .zero, size: size),
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
    // Hiding the app would order the panel out, which strands it off full-screen Spaces.
    panel.canHide = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    return panel
  }
}
