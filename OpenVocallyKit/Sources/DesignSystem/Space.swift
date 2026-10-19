import SwiftUI

/// Spacing on an 8 pt grid with 4 pt half steps. `xxs` is the only off-grid step, for the
/// gap between a title and its subtitle.
public enum Space: CGFloat, CaseIterable, Sendable {
  case xxs = 2
  case xs = 4
  case s = 8
  case m = 12
  case l = 16
  case xl = 20
  case xxl = 24
  case xxxl = 32

  public var points: CGFloat { rawValue }
}

/// Corner radii, drawn as continuous (squircle) corners.
public enum Radius: CGFloat, CaseIterable, Sendable {
  /// Thumbnails, badges, inline code.
  case small = 6
  /// Stat cards, chart panels, grouped lists.
  case card = 12
  /// Floating panels and popovers. The overlay has its own radii.
  case panel = 18

  public var points: CGFloat { rawValue }

  public var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: rawValue, style: .continuous)
  }
}

/// Square frames for icons that sit in a row of text.
public enum IconSize: CGFloat, CaseIterable, Sendable {
  /// An app icon or a symbol beside a row's text, such as a transcript or a top app.
  case row = 20
  /// The app icon heading a detail, such as the selected transcript's.
  case detail = 32

  public var points: CGFloat { rawValue }
}

extension View {
  public func padding(_ space: Space) -> some View {
    padding(space.rawValue)
  }

  public func padding(_ edges: Edge.Set, _ space: Space) -> some View {
    padding(edges, space.rawValue)
  }
}
