public enum DictationEvent: Sendable, Equatable {
  case command(DictationCommand, at: HostTime)
  case captureStarted(SessionID)
  case captureStopped(SessionID, samples: [Float])
  case transcribed(SessionID, Transcript)
  case processed(SessionID, Transcript)
  case pasted(SessionID, target: TargetApp?, at: HostTime)
  /// Auto-paste could not reach a text field; the transcript waits on the clipboard.
  case manualPasteNeeded(SessionID, at: HostTime)
  case manualPasteExpired(SessionID)
  case failed(SessionID, DictationFailureReason)
  case terminalDisplayEnded(SessionID)
  /// `Hold.confirmDelay` passed since a one-key hold started.
  case holdConfirmed(SessionID)
}
