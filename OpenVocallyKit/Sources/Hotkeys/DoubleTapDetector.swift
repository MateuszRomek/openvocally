import DictationCore

/// Recognizes a double tap of one modifier from flag changes. Shared by the matcher
/// and the Settings recorder. Fires on the second release, the first moment a press is known
/// not to become a chord such as ⌥A, so that release instant starts LB-01.
struct DoubleTapDetector: Sendable, Equatable {
  /// The longest press that still counts as a tap.
  static let tapMaxHold: Duration = .milliseconds(300)
  /// The longest gap from the first release to the second press.
  static let window: Duration = .milliseconds(300)

  enum State: Sendable, Equatable {
    case idle
    case firstDown(ModifierKey, at: HostTime)
    case firstUp(ModifierKey, at: HostTime)
    case secondDown(ModifierKey, at: HostTime)
  }

  private(set) var state = State.idle
  private var flags: Modifiers = []

  init() {}

  /// Returns the modifier on the second clean release.
  mutating func modifiersChanged(_ modifiers: Modifiers, at time: HostTime) -> ModifierKey? {
    // Fn, Caps Lock or the other side of a held modifier change nothing here.
    guard modifiers != flags else { return nil }
    let previous = flags
    flags = modifiers
    if modifiers.isEmpty {
      switch state {
      case .firstDown(let key, let pressedAt) where time.duration(since: pressedAt) <= Self.tapMaxHold:
        state = .firstUp(key, at: time)
        return nil
      case .secondDown(let key, let pressedAt) where time.duration(since: pressedAt) <= Self.tapMaxHold:
        state = .idle
        return key
      default:
        state = .idle
        return nil
      }
    }
    // A tap starts from no modifiers held; a second modifier joining or leaving is a chord.
    guard previous.isEmpty, let key = ModifierKey(modifiers) else {
      state = .idle
      return nil
    }
    if case .firstUp(let first, let releasedAt) = state, first == key,
      time.duration(since: releasedAt) <= Self.window
    {
      state = .secondDown(key, at: time)
    } else {
      state = .firstDown(key, at: time)
    }
    return nil
  }

  /// A key ends the gesture: ⌥ then a key is typing, not a tap. The key event's modifiers
  /// replace `flags`, so a lost release cannot block the next press.
  mutating func keyEvent(holding modifiers: Modifiers) {
    state = .idle
    flags = modifiers
  }

  /// For a click, a re-enabled tap or a rebind, where flag changes may have been lost.
  mutating func reset() {
    state = .idle
    flags = []
  }
}
