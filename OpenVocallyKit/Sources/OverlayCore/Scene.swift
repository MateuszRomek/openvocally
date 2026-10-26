import DictationCore

/// The live dictation state the strip shows.
package enum Voice: Sendable, Equatable {
  /// Pulse bars under "Recording": feedback never waits for the mic.
  case starting
  /// Still starting `NotchCore.connectingDelay` after the press.
  case connecting
  case recording
  /// Covers both stopping and transcribing.
  case transcribing
  case pasting
}

/// A message that stays until the dictation machine moves on.
package enum Notice: Sendable, Equatable {
  case manualPaste(until: HostTime)
  /// Never `.aborted`: a cancel shows nothing.
  case failure(DictationFailureReason)
}

/// A brief confirmation.
package enum Flash: Sendable, Equatable {
  case pasted
}

/// What leads the strip. A voice outranks a notice, and a notice outranks a flash.
package enum StripLead: Sendable, Equatable {
  case voice(Voice)
  case notice(Notice)
  case flash(Flash)
}

/// How much room the notch takes, smallest first.
package enum Footprint: Int, Comparable, CaseIterable, Sendable {
  case hidden, strip, noticeStrip

  package static func < (lhs: Footprint, rhs: Footprint) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// What the notch shows on one display.
package struct NotchScene: Sendable, Equatable {
  package let strip: StripLead?

  package static let hidden = NotchScene(strip: nil)

  package var footprint: Footprint {
    switch strip {
    case nil: .hidden
    case .voice, .flash: .strip
    case .notice: .noticeStrip
    }
  }
}

/// A scene to show on a display and how to move into it.
package struct NotchFrame: Sendable, Equatable {
  package let scene: NotchScene
  package let motion: MotionCue
}

/// The frames one event produced, empty when nothing visible changed.
package struct NotchOutcome: Sendable, Equatable {
  package let frames: [DisplayID: NotchFrame]
}
