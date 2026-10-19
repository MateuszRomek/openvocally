struct SessionRecord: Sendable, Equatable {
  let id: SessionID
  let mode: RecordingMode
  let pressedAt: HostTime
  let outcome: TerminalOutcome
  let target: TargetApp?
  /// The one-key hold that started the session, nil otherwise.
  let hold: Hold?
  /// What a Try it session heard. Never set for a real dictation.
  let trialTranscript: Transcript?
}
