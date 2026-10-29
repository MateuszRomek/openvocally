import Foundation

/// The strip beside the notch, or a notice dropped below it.
public enum OverlayLevel: Sendable {
  case compact, alert
}

/// `status` is always present, so VoiceOver always has a label. No glyph while the bars
/// carry the state.
struct OverlayActivity: Sendable, Equatable {
  var glyph: OverlayGlyph?
  public var status: StatusWord
  public var body: Body

  public enum Body: Sendable, Equatable {
    case compact(Trailing)
    case alert(OverlayAlert)
  }

  public enum Trailing: Sendable, Equatable {
    case status
    /// The status word stays as the accessibility label.
    case bars(BarsMode)
  }

  public init(glyph: OverlayGlyph?, status: StatusWord, body: Body) {
    self.glyph = glyph
    self.status = status
    self.body = body
  }

  public var level: OverlayLevel {
    switch body {
    case .compact: .compact
    case .alert: .alert
    }
  }
}

/// Under Reduce Motion every mode draws the same static shape.
public enum BarsMode: Sendable, Equatable {
  case pulse, live, sweep
}

/// Semantic glyphs, so the strip and the notice draw the same meaning.
public enum OverlayGlyph: Sendable, Equatable {
  case success
  case attention
}

/// The only text allowed at compact. `StaticString` cannot be interpolated, so
/// runtime text such as a transcript cannot become a status word.
public struct StatusWord: Sendable, Hashable, ExpressibleByStringLiteral {
  public let text: String

  public init(stringLiteral value: StaticString) {
    text = value.description
  }
}

/// One short line from a fixed copy table. `StaticString` keeps runtime text, such as
/// a transcript, out of the overlay.
public struct OverlayAlert: Sendable, Equatable {
  public let message: String
  public let keys: [String]
  let countdown: Countdown?
  /// The key caps are drawn, not spoken, so VoiceOver hears them after the message.
  public let accessibilityLabel: String

  public init(_ message: StaticString, keys: [String] = [], countdown: Countdown? = nil) {
    let text = message.description
    self.message = text
    self.keys = keys
    self.countdown = countdown
    self.accessibilityLabel =
      keys.isEmpty ? text : "\(text) \(keys.joined(separator: " "))"
  }
}

/// A window that closes at a wall-clock time. Any producer can build one without knowing
/// the dictation clock.
public struct Countdown: Sendable, Equatable {
  let ends: Date
  public let total: Duration

  public init(ends: Date, total: Duration) {
    self.ends = ends
    self.total = total
  }
}

extension OverlayActivity {
  /// What VoiceOver reads: the status word, or the alert with its keys.
  public var accessibilityLabel: String {
    switch body {
    case .compact: status.text
    case .alert(let alert): alert.accessibilityLabel
    }
  }
}
