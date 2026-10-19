import DictationCore

/// What the push-to-talk Try it card shows. The transcript stays in the card and is never logged.
public enum HoldTrial: Sendable, Equatable {
  case waiting
  case listening(level: Float)
  case heard(String)
  case failed(DictationFailureReason)

  /// Whether `update` belongs to the trial instead of the overlay. A trial update is claimed
  /// even with no card on screen, so it never reaches the overlay.
  public static func claims(_ update: DictationUpdate, trialActive: Bool) -> Bool {
    update.hold?.isTrial == true || update.trialResult != nil || (trialActive && update.phase == .idle)
  }

  /// The card after `update`. An aborted trial returns to waiting, not to an error. A
  /// recording update keeps the current level, and idle after listening returns to waiting.
  public func applying(_ update: DictationUpdate) -> HoldTrial {
    switch update.trialResult {
    case .heard(let transcript): .heard(transcript.text)
    case .failed(.aborted): .waiting
    case .failed(let reason): .failed(reason)
    case nil where update.phase.showsRecording:
      if case .listening = self { self } else { .listening(level: 0) }
    case nil where update.phase == .idle:
      if case .listening = self { .waiting } else { self }
    case nil: self
    }
  }

  /// The card after a microphone level tick, or nil when the tick changes nothing because the
  /// card isn't listening.
  public func heard(level: Float) -> HoldTrial? {
    if case .listening = self { .listening(level: level) } else { nil }
  }
}
