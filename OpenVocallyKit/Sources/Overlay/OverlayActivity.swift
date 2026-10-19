import Foundation

/// Ordered so a move up is a grow and a move down is a shrink. `hidden` is never stored: no
/// activity means hidden.
public enum OverlayLevel: Int, Comparable, Sendable {
  case hidden, compact, alert, card

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// `status` is always present, so VoiceOver always has a label. No glyph while the bars
/// carry the state.
public struct OverlayActivity: Sendable, Equatable {
  var glyph: OverlayGlyph?
  public var status: StatusWord
  public var body: Body

  public enum Body: Sendable, Equatable {
    case compact(Trailing)
    case alert(OverlayAlert)
    /// Reserved for agent review. Click-through until actions land with the agent.
    case card(OverlayCard)
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
    case .card: .card
    }
  }
}

/// Under Reduce Motion every mode draws the same static shape.
public enum BarsMode: Sendable, Equatable {
  case pulse, live, sweep
}

/// Semantic glyphs, so every style draws the same meaning. A new activity kind adds a case here.
public enum OverlayGlyph: Sendable, Equatable {
  case success
  case attention
  case agent
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

/// Runtime text, unlike `StatusWord` and `OverlayAlert`. Only the agent builds cards, and
/// dictation never does, so transcript text stays out of the overlay.
public struct OverlayCard: Sendable, Equatable {
  public let title: String
  public let detail: String?

  public init(title: String, detail: String? = nil) {
    self.title = title
    self.detail = detail
  }
}

extension OverlayActivity {
  /// What VoiceOver reads: the status word, the alert with its keys, or the card's text.
  public var accessibilityLabel: String {
    switch body {
    case .compact: status.text
    case .alert(let alert): alert.accessibilityLabel
    case .card(let card): [card.title, card.detail].compactMap(\.self).joined(separator: ", ")
    }
  }
}
