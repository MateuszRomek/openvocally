import AppKit
import DesignSystem
import SwiftUI

/// What the user picked in Settings. Missing or unknown values fall back to `notch`.
public enum OverlayStyle: String, CaseIterable, Sendable {
  case notch
  case island

  public static let defaultsKey = "overlayStyle"
  public static let fallback = Self.notch
}

/// The island's edge, under the original placement key and values so no migration is needed. Only the
/// island style reads it.
public enum IslandEdge: String, CaseIterable, Sendable {
  /// Above the bottom of the work area.
  case bottom = "islandBottom"
  /// Below the menu bar.
  case top = "islandTop"

  public static let defaultsKey = "overlayPlacement"
  public static let fallback = Self.bottom

  var anchor: VerticalEdge {
    switch self {
    case .bottom: .bottom
    case .top: .top
    }
  }
}

/// The stored choice. Resolved against a display by `placement(on:)` each appearance.
public struct OverlayPreference: Equatable, Sendable {
  public var style: OverlayStyle
  var edge: IslandEdge

  public init(style: OverlayStyle, edge: IslandEdge) {
    self.style = style
    self.edge = edge
  }

  public static func stored(in defaults: UserDefaults = .standard) -> Self {
    Self(
      style: defaults.string(forKey: OverlayStyle.defaultsKey).flatMap(OverlayStyle.init(rawValue:))
        ?? .fallback,
      edge: defaults.string(forKey: IslandEdge.defaultsKey).flatMap(IslandEdge.init(rawValue:))
        ?? .fallback)
  }

  /// A display without a notch shows the notch style as the top island, nearest to where the
  /// notch would be.
  func placement(on screen: ScreenGeometry) -> OverlayPlacement {
    switch style {
    case .notch: NotchGeometry(screen).map(OverlayPlacement.notch) ?? .island(.top)
    case .island: .island(edge)
    }
  }
}

/// What the stage draws. Resolved per display and never persisted.
public enum OverlayPlacement: Equatable, Sendable {
  case island(IslandEdge)
  case notch(NotchGeometry)

  func panelFrame(on screen: ScreenGeometry) -> CGRect {
    let size = OverlayMetrics.canvas
    let (midX, y) =
      switch self {
      case .island(.bottom):
        (screen.visibleFrame.midX, screen.visibleFrame.minY + OverlayMetrics.bottomInset)
      case .island(.top):
        (screen.frame.midX, screen.visibleFrame.maxY - OverlayMetrics.topInset - size.height)
      case .notch(let notch): (notch.midX, screen.frame.maxY - size.height)
      }
    return CGRect(x: midX - size.width / 2, y: y, width: size.width, height: size.height)
  }

  var anchor: VerticalEdge {
    switch self {
    case .island(let edge): edge.anchor
    case .notch: .top
    }
  }
}

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
