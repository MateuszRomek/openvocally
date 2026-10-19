public enum DictationCommand: Sendable, Equatable {
  case toggle
  case cancel
  case pushToTalkStart
  case pushToTalkStop
  case pasteLast
  /// The user pressed ⌘V while the manual paste window was open. The keystroke still reaches
  /// the focused app.
  case manualPaste
  /// One key went down alone. Recording starts now; the session is pending until
  /// `Hold.confirmDelay` passes with no other input.
  case holdStart(trial: Bool)
  /// Another key, click or modifier joined a one-key hold. The session ends with no cue, no
  /// transcript, no paste and no terminal display.
  case holdAbort
}

/// A session started by holding one key.
public struct Hold: Sendable, Equatable {
  /// The time with no other input that turns a pending hold into a real one.
  static let confirmDelay: Duration = .milliseconds(150)
  public var isConfirmed: Bool
  /// Try it in Settings: transcribe, never paste, never save, never archive.
  public let isTrial: Bool

  public init(isConfirmed: Bool, isTrial: Bool) {
    self.isConfirmed = isConfirmed
    self.isTrial = isTrial
  }
}

public enum DictationIntent: Sendable, Equatable {
  case ignore
  case start(RecordingMode, hold: Hold? = nil)
  case stop
  case cancel
  /// Silent end of a one-key hold: cancel capture, straight to idle.
  case discard
  case cancelTranscription
  case cancelManualPaste
  case manualPaste
  case pasteLast
}

extension DictationPhase {
  public func intent(for command: DictationCommand) -> DictationIntent {
    switch (command, self) {
    case (.cancel, .transcribing): .cancelTranscription
    case (.cancel, .awaitingManualPaste): .cancelManualPaste
    case (.cancel, .starting), (.cancel, .recording), (.cancel, .stopping): .cancel
    case (.cancel, _): .ignore

    case (.toggle, _) where canStartSession: .start(.toggle)
    case (.toggle, .starting(.toggle)): .cancel
    case (.toggle, .recording(.toggle)): .stop
    case (.toggle, _): .ignore

    case (.pushToTalkStart, _) where canStartSession: .start(.pushToTalk)
    case (.pushToTalkStart, _): .ignore

    case (.pushToTalkStop, .starting(.pushToTalk)): .cancel
    case (.pushToTalkStop, .recording(.pushToTalk)): .stop
    case (.pushToTalkStop, _): .ignore

    case (.pasteLast, _) where canStartSession: .pasteLast
    case (.pasteLast, _): .ignore

    case (.manualPaste, .awaitingManualPaste): .manualPaste
    case (.manualPaste, _): .ignore

    case (.holdStart, .awaitingManualPaste): .ignore
    case (.holdStart(let trial), _) where canStartSession:
      .start(.pushToTalk, hold: Hold(isConfirmed: false, isTrial: trial))
    case (.holdStart, _): .ignore

    case (.holdAbort, .starting(.pushToTalk)), (.holdAbort, .recording(.pushToTalk)): .discard
    case (.holdAbort, _): .ignore
    }
  }
}
