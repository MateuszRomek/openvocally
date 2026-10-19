import DictationCore

/// The Settings recorder as a value. Fed the same `KeyEvent`s as the tap, so key
/// caps, chords, double taps and one-key holds are recognized by tested code, not the view.
public struct ShortcutRecorder: Sendable, Equatable {
  public enum Step: Sendable, Equatable {
    case none
    /// Redraw the key caps.
    case held(HeldKeys)
    /// A chord or a double tap: saves at once.
    case save(HotkeyTrigger)
    /// One key was pressed and released alone on the push-to-talk row: show the card.
    case offerHold(HoldKey)
    case stop
    case unsupportedKey
  }

  public let action: HotkeyAction
  private var held: HeldKeys = []
  /// Set on a fresh press into exactly one key, cleared by any other key or modifier.
  private var candidate: HoldKey?
  private var doubleTap = DoubleTapDetector()

  public init(recording action: HotkeyAction) {
    self.action = action
  }

  public mutating func handle(_ event: KeyEvent, at time: HostTime) -> Step {
    switch event {
    case .modifiersChanged(let next):
      defer { held = next }
      if action == .pushToTalk {
        if held.isEmpty, let key = next.only {
          candidate = key
        } else if next.isEmpty, let key = candidate {
          candidate = nil
          return .offerHold(key)
        } else if next.only != candidate {
          candidate = nil
        }
      } else if let key = doubleTap.modifiersChanged(next.modifiers, at: time) {
        return .save(.doubleTap(key))
      }
      return .held(next)
    case .down(let key, let modifiers, let isAutorepeat):
      candidate = nil
      doubleTap.keyEvent(holding: modifiers)
      switch ShortcutCapture(key: key, modifiers: modifiers, isRepeat: isAutorepeat, recording: action) {
      case .ignore: return .none
      case .cancel: return .stop
      case .unsupportedKey: return .unsupportedKey
      case .record(let chord): return .save(.chord(chord))
      }
    case .up(_, let modifiers):
      candidate = nil
      doubleTap.keyEvent(holding: modifiers)
      return .none
    case .pointerDown:
      candidate = nil
      doubleTap.reset()
      return .none
    }
  }
}
