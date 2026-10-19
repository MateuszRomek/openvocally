public enum DictationPhase: Sendable, Equatable {
  case idle
  case starting(RecordingMode)
  case recording(RecordingMode)
  case stopping
  case transcribing
  case pasting
  /// The transcript is on the clipboard and the user's ⌘V pastes it until `until`.
  case awaitingManualPaste(until: HostTime)
  case complete
  case failed(DictationFailureReason)

  /// `.starting` shows as recording: feedback never waits for the mic.
  public var showsRecording: Bool {
    switch self {
    case .starting, .recording: true
    default: false
    }
  }

  var canStartSession: Bool {
    switch self {
    case .idle, .complete, .failed, .awaitingManualPaste: true
    case .starting, .recording, .stopping, .transcribing, .pasting: false
    }
  }
}
