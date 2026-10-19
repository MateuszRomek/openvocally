import Synchronization
import Transcription

/// Forwards to an engine and counts its calls, so the bench can tell when the runtime has
/// finished the work it does on a recording.
final class CountingTranscriber: Transcriber {
  struct Counts: Equatable {
    /// `transcribe` calls started.
    var transcribes = 0
    var transcribing = 0
    var pinging = 0
  }

  private let engine: any Transcriber
  private let state = Mutex(Counts())

  init(_ engine: any Transcriber) {
    self.engine = engine
  }

  var counts: Counts { state.withLock { $0 } }

  var lookahead: Lookahead { engine.lookahead }

  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    state.withLock {
      $0.transcribes += 1
      $0.transcribing += 1
    }
    defer { state.withLock { $0.transcribing -= 1 } }
    return try await engine.transcribe(samples)
  }

  func keepWarm() async {
    state.withLock { $0.pinging += 1 }
    defer { state.withLock { $0.pinging -= 1 } }
    await engine.keepWarm()
  }
}

/// Decides when the runtime has settled on a complete recording: it listened twice in a row to
/// the whole buffer with no engine call in flight or started in between. A runtime that stopped
/// listening (a whole-recording engine past its window) settles after `quietFor` with no listen
/// and no `transcribe` call; its pings to keep the hardware warm never stop.
struct SettleDetector {
  static let quietFor = Duration.milliseconds(1_500)

  private var lastListen: CountingTranscriber.Counts?
  private var lastEvent: (transcribes: Int, at: ContinuousClock.Instant)?
  private(set) var isSettled = false

  /// The runtime listened while the whole recording was appended.
  mutating func listened(_ counts: CountingTranscriber.Counts, at now: ContinuousClock.Instant) {
    lastEvent = (counts.transcribes, now)
    guard counts.transcribing == 0, counts.pinging == 0 else {
      lastListen = nil
      return
    }
    if lastListen == counts { isSettled = true }
    lastListen = counts
  }

  /// Polled while waiting. Settles once nothing has happened for `quietFor`.
  mutating func poll(_ counts: CountingTranscriber.Counts, at now: ContinuousClock.Instant) {
    guard let lastEvent, lastEvent.transcribes == counts.transcribes, counts.transcribing == 0 else {
      lastEvent = (counts.transcribes, now)
      return
    }
    if now - lastEvent.at >= Self.quietFor { isSettled = true }
  }
}

struct SettleTimeout: Error, CustomStringConvertible {
  let timeout: Duration
  var description: String { "the runtime did not settle within \(timeout)" }
}
