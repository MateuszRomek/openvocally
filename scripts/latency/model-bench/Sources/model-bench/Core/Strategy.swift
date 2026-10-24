import Models
import Transcription

/// One way to turn a recording into text. The feeder calls `start` once per run, `append` for each
/// 20 ms chunk while "recording", and `finish` at "release". The release-to-text clock covers only
/// `finish`; work done inside `append` counts as work during recording.
///
/// Add a strategy: one file in the engine's executable target with a type conforming to this
/// protocol, plus one entry in that target's `Registry.swift`.
protocol Strategy<Model>: Actor {
  /// Whatever the engine loads once before the warmup run, shared by all of its strategies.
  associatedtype Model: Sendable

  /// The name used on the command line and in results, for example `batch`.
  static var name: String { get }

  init(model: Model) async throws

  /// Resets per-recording state. Called before the first `append` of every run.
  func start() async

  /// One 20 ms chunk (320 samples at 16 kHz mono), in recording order.
  func append(_ chunk: [Float]) async

  /// Waits, after the last `append`, until no work the strategy would do on this recording
  /// before the release is left. Used by `--pace settled`.
  func settle(timeout: Duration) async throws

  /// The final text for everything appended since `start`.
  func finish() async throws -> String
}

extension Strategy {
  func settle(timeout: Duration) async throws {}
}

/// An engine model that can transcribe a whole recording in one call, the shipping behaviour.
protocol WholeBufferTranscriber: Sendable {
  /// The shipping transcriber, as the app's `TranscriptionRuntime` holds it.
  var engine: any Transcriber { get }
  func transcribeAll(_ samples: [Float]) async throws -> String
}

/// The baseline: buffer every chunk, transcribe the whole buffer after release.
actor BatchStrategy<Model: WholeBufferTranscriber>: Strategy {
  static var name: String { "batch" }

  private let model: Model
  private var buffer: [Float] = []

  init(model: Model) async throws {
    self.model = model
  }

  func start() {
    buffer.removeAll(keepingCapacity: true)
  }

  func append(_ chunk: [Float]) {
    buffer.append(contentsOf: chunk)
  }

  func finish() async throws -> String {
    try await model.transcribeAll(buffer)
  }
}

/// What the app ships, for any engine: the real `TranscriptionRuntime` warms the engine on the
/// press and listens to the recording (`warm(listening:)`, which keeps pinging and transcribes
/// planned inputs at pauses), then transcribes on the release. Any latency work that lands in the
/// runtime or an engine shows up here without a new strategy.
actor ShippingStrategy<Model: WholeBufferTranscriber>: Strategy {
  static var name: String { "shipping" }

  private let runtime: TranscriptionRuntime
  private let engine: CountingTranscriber
  private var buffer: [Float] = []
  private var detector: SettleDetector?

  init(model: Model) async throws {
    try await self.init(engine: model.engine)
  }

  init(engine: any Transcriber) async throws {
    let engine = CountingTranscriber(engine)
    self.engine = engine
    runtime = TranscriptionRuntime { _ in engine }
    if case .hosted(let model) = ModelID.preferred.provider { await runtime.activate(.hosted(model)) }
  }

  func start() async {
    buffer.removeAll(keepingCapacity: true)
    detector = nil
    await runtime.warm(listening: { [weak self] in await self?.soFar() })
  }

  private func soFar() -> [Float] {
    detector?.listened(engine.counts, at: .now)
    return buffer
  }

  func settle(timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    detector = SettleDetector()
    while detector?.isSettled == false {
      guard ContinuousClock.now < deadline else { throw SettleTimeout(timeout: timeout) }
      try await Task.sleep(for: .milliseconds(5))
      detector?.poll(engine.counts, at: .now)
    }
  }

  func append(_ chunk: [Float]) {
    buffer.append(contentsOf: chunk)
  }

  func finish() async throws -> String {
    try await runtime.transcribe(buffer)
  }
}
