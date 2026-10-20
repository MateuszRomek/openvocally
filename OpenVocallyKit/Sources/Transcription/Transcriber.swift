public enum TranscriptionError: Error, Equatable, Sendable {
  case modelNotInstalled
  case noSpeech
  case engineFailed
  case cancelled
}

public protocol Transcriber: Sendable {
  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String
  /// Cheap throwaway work that keeps the hardware from clocking down while the user records. A
  /// ping may still run when `transcribe` starts, so it must not share engine state with it.
  func keepWarm() async
  /// What the runtime may transcribe while the user is still recording, so the release reuses it.
  var lookahead: Lookahead { get }
  /// A session that transcribes while the user records, so the release only finishes it. Nil for
  /// an engine that transcribes whole recordings. Called at the press, so its setup overlaps the
  /// recording. `transcribe(_:)` stays the fallback when the stream can't be used.
  func openStream() async throws(TranscriptionError) -> (any TranscriptionStream)?
}

extension Transcriber {
  public func keepWarm() async {}
  public var lookahead: Lookahead { .off }
  public func openStream() async throws(TranscriptionError) -> (any TranscriptionStream)? { nil }
}

/// One recording's streaming session: appends, then exactly one `finish` or `cancel`.
public protocol TranscriptionStream: Sendable {
  /// Appends 16 kHz samples that directly follow those already appended. Cheap and synchronous;
  /// a failure surfaces at `finish`.
  func append(_ samples: ArraySlice<Float>)
  /// Appends the last samples, ends the input and returns the final text. `.noSpeech` when empty.
  func finish(_ rest: ArraySlice<Float>) async throws(TranscriptionError) -> String
  /// Ends the session without a result. Safe after `finish` and safe to call twice.
  func cancel() async
}

/// What the runtime transcribes before the release.
public enum Lookahead: Sendable, Equatable {
  /// Everything is transcribed at the release, untrimmed.
  case off
  /// At a pause, the whole recording as the release would send it, while it is at most `window`
  /// samples. For engines that handle long audio themselves.
  case wholeRecording(window: Int)
  /// Cut at a pause once a piece holds `shortest` samples, or at the quietest 20 ms of the last
  /// 2 s once it reaches `longest`. Each closed piece is transcribed as it closes, the open tail
  /// at a pause, and the release decodes only what is left. Texts join with a space.
  case pieces(shortest: Int, longest: Int)
}
