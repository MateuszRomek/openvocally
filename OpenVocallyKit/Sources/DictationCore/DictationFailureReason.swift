public enum DictationFailureReason: Sendable, Equatable {
  case microphonePermissionDenied
  case captureError(CaptureFailure)
  case aborted
  case transcriptionError
  /// The hold was silent or too short to transcribe.
  case noSpeech
  case modelNotInstalled
  case pasteNotSupported
  case pastePermissionDenied
  case pasteRuntimeError
  /// Paste-last before any dictation produced text.
  case nothingToPaste
  /// Nobody pressed ⌘V within the manual paste window. The text is still in history.
  case manualPasteExpired
}

extension DictationFailureReason {
  /// A cancel or an unused manual paste window is the user's choice, so it plays no error cue.
  var isError: Bool {
    switch self {
    case .aborted, .manualPasteExpired: false
    default: true
    }
  }
}
