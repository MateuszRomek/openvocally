import AppKit
import SwiftUI

/// Colors by meaning. The chrome is monochrome like the app icon: black ink in light mode,
/// white in dark. Hue appears only where it carries a signal (recording, success, attention,
/// destructive), and only on small glyphs. Each value is a dynamic system color, so it
/// follows light, dark and Increase Contrast. Text uses the hierarchical styles `.primary`,
/// `.secondary` and `.tertiary` instead, which stay vibrant on materials.
public enum SemanticColor: String, CaseIterable, Sendable {
  /// Selection, the app tint and the one highlight per screen. Monochrome ink.
  case accent
  /// Text and glyphs drawn on an `accent` fill.
  case onAccent
  case recording
  case success
  /// Something needs the user, such as a missing permission.
  case attention
  case destructive
  /// Behind the selected row in a sidebar. A faint ink wash, so the row keeps its own text color.
  case selection
  case separator
  case windowBackground
  /// Behind lists and other scrolling content.
  case contentBackground

  public var color: Color {
    switch self {
    case .accent: Color(nsColor: .labelColor)
    case .onAccent: Color(nsColor: .textBackgroundColor)
    case .recording, .destructive: Color(nsColor: .systemRed)
    case .success: Color(nsColor: .systemGreen)
    case .attention: Color(nsColor: .systemOrange)
    case .selection: Color(nsColor: .quinaryLabelColor)
    case .separator: Color(nsColor: .separatorColor)
    case .windowBackground: Color(nsColor: .windowBackgroundColor)
    case .contentBackground: Color(nsColor: .controlBackgroundColor)
    }
  }
}

extension ShapeStyle where Self == Color {
  public static func token(_ color: SemanticColor) -> Color {
    color.color
  }
}
