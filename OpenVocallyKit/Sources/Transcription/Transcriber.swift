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
}

extension Transcriber {
  public func keepWarm() async {}
  public var lookahead: Lookahead { .off }
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
