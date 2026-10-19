import SwiftUI

/// The app's type scale. macOS has no Dynamic Type, so each style has one size; the system
/// text styles carry Apple's tracking and leading for it. Weight changes go through
/// `fontWeight(_:)` at the call site.
public enum TextStyle: String, CaseIterable, Sendable {
  case largeTitle
  case title1
  case title2
  case title3
  case headline
  case body
  case callout
  case subheadline
  case footnote
  case caption
  /// One large number with a grey label beside it, for stats and day groups.
  case numeral
  /// Paths, identifiers and anything the user may copy character by character.
  case code
  case overlayLabel
  case overlayGlyph

  var font: Font {
    switch self {
    case .largeTitle: .largeTitle
    case .title1: .title
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .body: .body
    case .callout: .callout
    case .subheadline: .subheadline
    case .footnote: .footnote
    case .caption: .caption
    case .numeral: .system(size: 28, weight: .semibold).monospacedDigit()
    case .code: .caption.monospaced()
    case .overlayLabel: .system(size: 12, weight: .medium)
    case .overlayGlyph: .system(size: 11, weight: .semibold)
    }
  }

  /// Nominal size in points, from the macOS text style table in the HIG.
  public var points: Double {
    switch self {
    case .largeTitle: 26
    case .title1: 22
    case .title2: 17
    case .title3: 15
    case .headline, .body: 13
    case .callout, .overlayLabel: 12
    case .subheadline, .overlayGlyph: 11
    case .footnote, .caption, .code: 10
    case .numeral: 28
    }
  }
}

/// Extra space between lines, on top of the font's own.
public enum LineSpacing: CGFloat, CaseIterable, Sendable {
  /// Long text read in full, such as a transcript in its detail.
  case reading = 4

  public var points: CGFloat { rawValue }
}

extension View {
  public func textStyle(_ style: TextStyle) -> some View {
    font(style.font)
  }
}
