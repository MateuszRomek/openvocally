import FluidAudio
import Foundation
import Models
import os

public enum RuntimeState: Sendable, Equatable {
  case notInstalled
  case loading
  /// Loaded, or unloaded after idling and loadable again on the next dictation.
  case ready
  case failed
}

/// Keeps the active model loaded. It loads at launch and after a model change, unloads
/// after 20 idle minutes, and loads again when the next dictation starts.
public actor TranscriptionRuntime {
  public typealias Loader = @Sendable (ResolvedModel) async throws(TranscriptionError) -> any Transcriber
  public typealias Load = Task<Result<any Transcriber, TranscriptionError>, Never>
  /// The 16 kHz recording so far, each sample as the final recording will have it, or nil once
  /// the recording ended.
  public typealias Listen = @Sendable () async -> [Float]?

  /// One engine call started while the user recorded, keyed by where its input starts in the
  /// recording and the exact samples it was given.
  struct EarlyCall {
    let start: Int
    let input: [Float]
    let result: Task<Result<String, TranscriptionError>, Never>

    func decoded(_ range: Range<Int>, of samples: [Float]) -> Bool {
      start == range.lowerBound && input[...] == samples[range]
    }
  }

  /// A stream that may still be opening, so a release before it opens waits for it instead of
  /// starting a second session.
  struct Streaming {
    let session: Task<(any TranscriptionStream)?, Never>
    var feed = StreamFeed()
  }

  /// Every state change. The stream has one reader, the model library; others call `settled()`.
  nonisolated let states: AsyncStream<RuntimeState>
  private let continuation: AsyncStream<RuntimeState>.Continuation
  private let load: Loader
  private let idleTimeout: Duration
  private let sleep: @Sendable (Duration) async -> Void
  private let now: @Sendable () -> ContinuousClock.Instant

  private var model: ResolvedModel?
  private var loaded: Load?
  private var inUse = 0
  private var idleTimer: Task<Void, Never>?
  private var warming: Task<Void, Never>?
  private let warmInterval: Duration
  private let listenInterval: Duration
  private var early: [EarlyCall] = []
  /// The stream the current recording is fed into, for an engine that streams.
  private var streaming: Streaming?
  private var drained: [CheckedContinuation<Void, Never>] = []
  private var isShutDown = false

  public init(
    idleTimeout: Duration = .seconds(20 * 60),
    warmInterval: Duration = .seconds(1),
    listenInterval: Duration = .milliseconds(100),
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    load: @escaping Loader
  ) {
    (states, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.load = load
    self.idleTimeout = idleTimeout
    self.warmInterval = warmInterval
    self.listenInterval = listenInterval
    self.sleep = sleep
    self.now = now
  }

  public static func live(folder: ModelFolder) -> TranscriptionRuntime {
    // FluidAudio can log transcript text. Set before the first load.
    AppLogger.minimumLevel = .warning
    return TranscriptionRuntime { (loaded) throws(TranscriptionError) in
      switch loaded {
      case .hosted(let model):
        switch model.engine {
        case .parakeet(let variant):
          return try await ParakeetTranscriber.load(variant, modelDirectory: folder.location(of: model))
        case .whisper: return try await WhisperTranscriber.load(modelFile: folder.location(of: model))
        }
      case .system(let model, let locale): return try await AppleSpeech.load(model, locale: locale)
      }
    }
  }

  /// Switches to `model` and starts loading it. `nil` means no model is installed.
  public func activate(_ model: ResolvedModel?) {
    guard !isShutDown, model != self.model || loaded == nil else { return }
    loaded?.cancel()
    loaded = nil
    warming?.cancel()
    for call in early { call.result.cancel() }
    early = []
    dropStream()
    self.model = model
    guard model != nil else {
      continuation.yield(.notInstalled)
      return
    }
    _ = startLoad()
  }

  /// Loads the active model if it was unloaded, then keeps it warm until `coolDown()` or the next
  /// `transcribe`. The pipeline calls this on the press, so the load overlaps the recording, and the
  /// Neural Engine stays clocked up for the release. With `listen`, it transcribes ahead what
  /// the release would send, as the engine's `lookahead` allows, so the release reuses it.
  public func warm(listening listen: Listen? = nil) {
    guard !isShutDown, model != nil else { return }
    let load = loaded ?? startLoad()
    let previous = warming
    previous?.cancel()
    let interval = warmInterval
    let tick = listen == nil ? interval : min(interval, listenInterval)
    let sleep = sleep
    let now = now
    warming = Task {
      await previous?.value
      early = []
      dropStream()
      guard case .success(let transcriber) = await load.value else { return }
      if let listen, !Task.isCancelled,
        await stream(listen, into: transcriber, tick: tick, until: now() + interval * Self.maxPings)
      {
        return
      }
      // A bound, so a recording that never reaches a stop cannot ping forever.
      let deadline = now() + interval * Self.maxPings
      var idleSince: ContinuousClock.Instant?
      let lookahead = transcriber.lookahead
      var planner = listen == nil || lookahead == .off ? nil : ReleasePlanner(lookahead)
      while !Task.isCancelled, now() < deadline {
        let recording = planner == nil ? nil : await listen?()
        guard !Task.isCancelled else { break }
        let pace = recording.map { Self.listenPause(tick, recorded: $0.count) } ?? tick
        if let recording, let plan = planner?.plan(recording) {
          switch nextEarlyInput(plan, in: recording, for: lookahead) {
          case .start(let range):
            await transcribeEarly(range, of: recording, with: transcriber)
            idleSince = now()
            await sleep(pace)
            continue
          case .stopListening:
            planner = nil
          case .nothing:
            break
          }
        }
        if idleSince.map({ now() - $0 >= interval }) ?? true {
          await transcriber.keepWarm()
          idleSince = now()
        }
        await sleep(planner == nil ? interval : pace)
      }
    }
  }

  /// Opens the engine's stream and feeds it the recording as it grows, until the release takes
  /// it. False when the engine doesn't stream.
  private func stream(
    _ listen: Listen, into transcriber: any Transcriber, tick: Duration,
    until deadline: ContinuousClock.Instant
  ) async -> Bool {
    let session = Task { () -> (any TranscriptionStream)? in
      do throws(TranscriptionError) {
        return try await transcriber.openStream()
      } catch {
        transcriptionLogger.error("Couldn't open a stream: \(String(describing: error), privacy: .public)")
        return nil
      }
    }
    streaming = Streaming(session: session)
    guard let stream = await session.value else {
      if streaming?.session == session { streaming = nil }
      return false
    }
    while !Task.isCancelled, now() < deadline {
      guard let recording = await listen() else { break }
      guard !Task.isCancelled, streaming?.session == session else { break }
      if let samples = streaming?.feed.next(recording) { stream.append(samples) }
      await sleep(Self.listenPause(tick, recorded: recording.count))
    }
    return true
  }

  /// Cancels the open stream, if any, in the background: nothing waits on a dropped session.
  private func dropStream() {
    guard let session = streaming?.session else { return }
    streaming = nil
    Task { await session.value?.cancel() }
  }

  /// Finishes the stream with what it has not had yet. Nil when there is no stream, or it heard
  /// a different recording or failed, so the caller transcribes the whole recording instead.
  private func finishStream(_ samples: [Float]) async throws(TranscriptionError) -> String? {
    guard let streaming else { return nil }
    self.streaming = nil
    guard let stream = await streaming.session.value else { return nil }
    guard let rest = streaming.feed.rest(of: samples) else {
      transcriptionLogger.notice("The stream heard a different recording; transcribing it whole")
      await stream.cancel()
      return nil
    }
    do {
      return try await stream.finish(rest)
    } catch .noSpeech {
      throw .noSpeech
    } catch .cancelled where Task.isCancelled {
      throw .cancelled
    } catch {
      transcriptionLogger.error("The stream failed: \(String(describing: error), privacy: .public)")
      await stream.cancel()
      return nil
    }
  }

  /// Each listen resamples the whole recording so far, so the pause grows with the recording to
  /// keep that cost per second flat: 100 ms at 50 s, a second at 8 minutes.
  static func listenPause(_ tick: Duration, recorded samples: Int) -> Duration {
    max(tick, .milliseconds(samples / 8_000))
  }

  enum EarlyInput {
    case start(Range<Int>)
    case stopListening
    case nothing
  }

  /// The first input of `plan` that is safe to start now and was not started for these samples:
  /// every piece, then the tail once it is settled and fits the window.
  private func nextEarlyInput(
    _ plan: ReleasePlan, in recording: [Float], for lookahead: Lookahead
  ) -> EarlyInput {
    // The recording only grows, so while it does the range alone identifies a call; the release
    // compares samples.
    let started = { (range: Range<Int>) in
      self.early.contains { $0.start == range.lowerBound && $0.input.count == range.count }
    }
    if let piece = plan.pieces.first(where: { !started($0) }) { return .start(piece) }
    guard let tail = plan.tail else { return .nothing }
    if lookahead.outgrows(tail) { return .stopListening }
    return plan.tailIsSettled && !started(tail) ? .start(tail) : .nothing
  }

  /// Transcribes in its own task, so the release can keep a call it reuses and cancel one it
  /// won't, and waits for it, so the loop never has two calls in flight. Drops an earlier
  /// settled tail with the same start, which this one supersedes.
  private func transcribeEarly(
    _ range: Range<Int>, of recording: [Float], with transcriber: any Transcriber
  ) async {
    let input = Array(recording[range])
    let result = Task { () -> Result<String, TranscriptionError> in
      do throws(TranscriptionError) {
        return .success(try await transcriber.transcribe(input))
      } catch {
        return .failure(error)
      }
    }
    let call = EarlyCall(start: range.lowerBound, input: input, result: result)
    early.removeAll { $0.start == range.lowerBound }
    early.append(call)
    _ = await result.value
  }

  /// Cancels `calls` and waits for them, since they share the engine with whatever runs next.
  private func drain(_ calls: [EarlyCall]) async {
    for call in calls { call.result.cancel() }
    for call in calls { _ = await call.result.value }
  }

  static let maxPings = 600

  /// Stops keeping the model warm and cancels every early call, so a cancelled dictation frees
  /// the engine. A ping already running finishes on its own.
  public func coolDown() {
    warming?.cancel()
    for call in early { call.result.cancel() }
    dropStream()
  }

  var isLoaded: Bool { loaded != nil }

  /// The state once the active model's load ends. For a caller that can't read `states`, whose
  /// one reader is the model library once it starts.
  public func settled() async -> RuntimeState {
    guard let loaded else { return model == nil ? .notInstalled : .failed }
    switch await loaded.value {
    case .success: return .ready
    case .failure(let error): return error == .modelNotInstalled ? .notInstalled : .failed
    }
  }

  /// Cancels the idle timer, early calls and a pending load, waits for them, then waits
  /// for in-flight transcriptions, whose callers cancel them, so no model outlives the call: a Whisper
  /// context still alive at exit aborts the process. Terminal, and safe to call again.
  public func shutDown() async {
    isShutDown = true
    idleTimer?.cancel()
    idleTimer = nil
    warming?.cancel()
    let calls = early
    early = []
    await drain(calls)
    await finishWarming()
    let session = streaming?.session
    streaming = nil
    await session?.value?.cancel()
    let pending = loaded
    loaded = nil
    pending?.cancel()
    // whisper_init can't be interrupted; the loader frees a context created after the cancel,
    // and a model that finished loading is released when this result is dropped.
    _ = await pending?.value
    while inUse > 0 {
      await withCheckedContinuation { drained.append($0) }
    }
  }

  /// Callers run one transcription at a time.
  public func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    guard !isShutDown else { throw .cancelled }
    guard model != nil else { throw .modelNotInstalled }
    let load = loaded ?? startLoad()
    inUse += 1
    // A ping still running finishes beside this call: it uses the Core ML models directly, which
    // run predictions concurrently, and waiting for it cost up to 95 ms.
    warming?.cancel()
    defer {
      early = []
      inUse -= 1
      if inUse == 0 {
        for waiter in drained { waiter.resume() }
        drained.removeAll()
      }
      if !isShutDown { scheduleUnload() }
    }
    let transcriber = try await load.value.get()
    if let text = try await finishStream(samples) { return text }
    guard transcriber.lookahead != .off else { return try await transcriber.transcribe(samples) }
    let plan = ReleasePlanner.plan(finished: samples, transcriber.lookahead)
    let calls = early
    early = []
    let parts = plan.inputs.map { range in
      calls.first { $0.decoded(range, of: samples) }.map(Part.started) ?? .pending(range)
    }
    let reused = parts.compactMap { part in
      if case .started(let call) = part { call.result } else { nil }
    }
    await drain(calls.filter { call in !reused.contains(call.result) })
    let result = await withTaskCancellationHandler { () -> Result<String, TranscriptionError> in
      do throws(TranscriptionError) {
        return .success(try await joined(parts, of: samples, with: transcriber))
      } catch {
        return .failure(error)
      }
    } onCancel: {
      for task in reused { task.cancel() }
    }
    return try result.get()
  }

  enum Part {
    case started(EarlyCall)
    case pending(Range<Int>)
  }

  /// Decodes in order, reusing started calls. A started call that failed for any reason other
  /// than no speech runs again. A part with no speech adds nothing; no text at all is `.noSpeech`.
  private func joined(
    _ parts: [Part], of samples: [Float], with transcriber: any Transcriber
  ) async throws(TranscriptionError) -> String {
    var texts: [String] = []
    for part in parts {
      let input: [Float]
      switch part {
      case .started(let call):
        switch await call.result.value {
        case .success(let text):
          transcriptionLogger.info("Reused a transcription made while recording")
          texts.append(text)
          continue
        case .failure(.noSpeech): continue
        case .failure(.cancelled) where Task.isCancelled: throw .cancelled
        case .failure: input = call.input
        }
      case .pending(let range):
        input = Array(samples[range])
      }
      do {
        texts.append(try await transcriber.transcribe(input))
      } catch .noSpeech {
        continue
      }
    }
    guard !texts.isEmpty else { throw .noSpeech }
    return texts.joined(separator: " ")
  }

  private func finishWarming() async {
    guard let warming else { return }
    warming.cancel()
    await warming.value
    if self.warming == warming { self.warming = nil }
  }

  private func startLoad() -> Load {
    guard let model else { preconditionFailure("startLoad needs an active model") }
    continuation.yield(.loading)
    let load = load
    let task = Load {
      do throws(TranscriptionError) {
        return .success(try await load(model))
      } catch {
        return .failure(error)
      }
    }
    loaded = task
    Task { await finished(task) }
    return task
  }

  private func finished(_ task: Load) async {
    let result = await task.value
    guard task == loaded else { return }
    switch result {
    case .success:
      continuation.yield(.ready)
      scheduleUnload()
    case .failure(let error):
      // The next dictation tries again instead of failing until the app restarts.
      loaded = nil
      continuation.yield(error == .modelNotInstalled ? .notInstalled : .failed)
    }
  }

  private func scheduleUnload() {
    idleTimer?.cancel()
    let sleep = sleep
    let timeout = idleTimeout
    idleTimer = Task {
      await sleep(timeout)
      guard !Task.isCancelled else { return }
      unloadIfIdle()
    }
  }

  private func unloadIfIdle() {
    guard inUse == 0, let loaded else { return }
    warming?.cancel()
    dropStream()
    loaded.cancel()
    self.loaded = nil
  }
}

extension Lookahead {
  /// A whole-recording engine stops listening once the trimmed tail passes its window, since the
  /// tail only grows from there.
  func outgrows(_ tail: Range<Int>) -> Bool {
    guard case .wholeRecording(let window) = self else { return false }
    return tail.count > window
  }
}
