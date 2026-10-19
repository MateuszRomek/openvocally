public enum DictationEffect: Sendable, Equatable {
  case startCapture(SessionID, pressedAt: HostTime)
  case stopCapture(SessionID, releasedAt: HostTime)
  case cancelCapture(SessionID)
  case transcribe(SessionID, samples: [Float])
  case process(SessionID, Transcript)
  case paste(SessionID, Transcript)
  case pasteLast(SessionID, Transcript)
  /// Reports `.manualPasteExpired` after the duration unless the session moved on.
  case expireManualPaste(SessionID, after: Duration)
  /// The user pressed ⌘V: confirm the paste and restore the clipboard after it.
  case completeManualPaste(SessionID)
  /// Restores the clipboard now. Every exit from the manual window other than a paste.
  case abandonManualPaste(SessionID)
  case endTerminalDisplay(SessionID, after: Duration)
  case latency(LatencyMark)
  case playCue(SoundCue)
  case save(DictationEntry)
  case keepRecording(SessionID, samples: [Float])
  case discardRecording(SessionID)
  case failRecording(SessionID, DictationFailureReason)
  /// Reports `.holdConfirmed` at `at`, the press plus `Hold.confirmDelay`.
  case confirmHold(SessionID, at: HostTime)
}

public enum LatencyMark: Sendable, Equatable {
  case releaseToPasted(Duration)
}
