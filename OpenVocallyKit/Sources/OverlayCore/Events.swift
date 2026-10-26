import DictationCore

/// A display the notch can appear on, keyed by its Core Graphics display ID.
package struct DisplayID: Hashable, Sendable {
  package let rawValue: UInt32

  package init(rawValue: UInt32) {
    self.rawValue = rawValue
  }
}

/// Everything the notch reacts to.
package enum NotchEvent: Sendable, Equatable {
  case dictation(DictationPhase)
  case pointer(movedOnto: DisplayID)
  case tick

  var cause: Cause {
    switch self {
    case .dictation(let phase):
      switch phase {
      case .starting, .recording, .stopping, .failed(.aborted): .key
      case .transcribing, .pasting, .complete, .failed, .awaitingManualPaste, .idle: .arrival
      }
    case .pointer: .pointer
    case .tick: .timer
    }
  }
}

/// Why the scene changed, which decides how the change moves.
package enum Cause: Sendable, CaseIterable {
  case key, pointer, arrival, timer
}
