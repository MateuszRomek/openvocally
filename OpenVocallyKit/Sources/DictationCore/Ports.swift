/// The text step between transcription and paste. Non-throwing on purpose: a processor that
/// fails returns its input, so a cleanup outage never costs the user their dictation.
public struct TextProcessor: Sendable {
  public let process: @Sendable (Transcript) async -> Transcript

  public init(_ process: @escaping @Sendable (Transcript) async -> Transcript) {
    self.process = process
  }

  public static let passThrough = TextProcessor { $0 }
}

/// Where a recording's audio waits while it is transcribed. Kept until the transcript
/// arrives, then discarded; a failed transcription keeps it for a while.
public struct RecordingSink: Sendable {
  public var keep: @Sendable (SessionID, [Float]) async -> Void
  public var discard: @Sendable (SessionID) async -> Void
  public var fail: @Sendable (SessionID, DictationFailureReason) async -> Void

  public init(
    keep: @escaping @Sendable (SessionID, [Float]) async -> Void,
    discard: @escaping @Sendable (SessionID) async -> Void,
    fail: @escaping @Sendable (SessionID, DictationFailureReason) async -> Void
  ) {
    self.keep = keep
    self.discard = discard
    self.fail = fail
  }

  public static let none = RecordingSink(keep: { _, _ in }, discard: { _ in }, fail: { _, _ in })
}
