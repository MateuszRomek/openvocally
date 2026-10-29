import AppKit

struct ScreenGeometry: Equatable, Sendable {
  var frame: CGRect
  var visibleFrame: CGRect
  var safeAreaTop: CGFloat = 0
  var auxiliaryTopLeft: CGRect?
  var auxiliaryTopRight: CGRect?
}

extension ScreenGeometry {
  @MainActor init(_ screen: NSScreen) {
    self.init(
      frame: screen.frame, visibleFrame: screen.visibleFrame,
      safeAreaTop: screen.safeAreaInsets.top,
      auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
      auxiliaryTopRight: screen.auxiliaryTopRightArea)
  }

  /// A display's own menu bar is the gap above its visible frame. An auto-hidden menu bar leaves
  /// no gap, so `fallback` stands in.
  func menuBarHeight(fallback: CGFloat) -> CGFloat {
    let gap = frame.maxY - visibleFrame.maxY
    return gap > 0 ? gap : fallback
  }
}

enum MenuBarPresence {
  /// The displays that have a menu bar, from `ordered` with the primary display first. Without
  /// separate Spaces only the primary display has one.
  static func displays<ID>(_ ordered: [ID], separateSpaces: Bool) -> [ID] {
    separateSpaces ? ordered : Array(ordered.prefix(1))
  }
}

/// The hardware notch in global screen points.
public struct NotchGeometry: Equatable, Sendable {
  public let size: CGSize
  /// From the auxiliary areas' widths, so it holds whether AppKit reports them in global or
  /// screen-local points, and never assumed to be the screen's centre.
  public let midX: CGFloat

  init(size: CGSize, midX: CGFloat) {
    self.size = size
    self.midX = midX
  }

  init?(_ screen: ScreenGeometry) {
    guard screen.safeAreaTop > 0, let left = screen.auxiliaryTopLeft,
      let right = screen.auxiliaryTopRight
    else { return nil }
    let width = screen.frame.width - left.width - right.width
    guard width > 0, width < screen.frame.width / 2 else { return nil }
    self.init(
      size: CGSize(width: width, height: screen.safeAreaTop),
      midX: screen.frame.minX + left.width + width / 2)
  }

  var hiddenSize: CGSize {
    CGSize(
      width: size.width - OverlayMetrics.notchIdleShrink.width,
      height: size.height - OverlayMetrics.notchIdleShrink.height)
  }

  /// For the Design Gallery and previews on a Mac without a notch.
  public static let simulated = NotchGeometry(size: OverlayMetrics.notchSimulated, midX: 0)
}
