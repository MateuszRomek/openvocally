/// A dictation that produced text, saved to history with its metrics in one transaction.
/// Written when the session ends, so a failed paste still keeps the text.
public struct DictationEntry: Sendable, Equatable {
  public let session: SessionID
  public let mode: RecordingMode
  public let pressedAt: HostTime
  /// Press to release.
  public let recordingDuration: Duration
  public let transcript: Transcript
  public let target: TargetApp?

  public init(
    session: SessionID, mode: RecordingMode, pressedAt: HostTime, recordingDuration: Duration,
    transcript: Transcript, target: TargetApp?
  ) {
    self.session = session
    self.mode = mode
    self.pressedAt = pressedAt
    self.recordingDuration = recordingDuration
    self.transcript = transcript
    self.target = target
  }
}
