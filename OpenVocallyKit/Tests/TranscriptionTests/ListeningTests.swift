import Synchronization
import Testing

@testable import Transcription

/// Answers with the input length and counts the calls. The first `failures` calls fail.
final class CountingTranscriber: Sendable, Transcriber {
  private let calls = Mutex<[Int]>([])
  private let failures: Int
  let lookahead: Lookahead

  init(failures: Int = 0, lookahead: Lookahead = .wholeRecording(window: 15 * second)) {
    self.failures = failures
    self.lookahead = lookahead
  }

  var inputs: [Int] { calls.withLock { $0 } }

  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    let call = calls.withLock { calls in
      calls.append(samples.count)
      return calls.count
    }
    guard call > failures else { throw .engineFailed }
    return "\(samples.count)"
  }
}

/// Holds its one call until the test opens it, ignoring cancellation as an engine call does, and
/// reports when the call started and when it was cancelled.
final class HeldTranscriber: Sendable, Transcriber {
  let started = Gate()
  let cancelled = Gate()
  private let release = Gate()
  private let cancels = Mutex(0)

  var lookahead: Lookahead { .pieces(shortest: 2 * second, longest: 4 * second) }
  var cancellations: Int { cancels.withLock { $0 } }

  func open() { release.open() }

  /// Reports the start from inside the cancellation handler, so a cancel after it reaches the
  /// handler before `cancel()` returns.
  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    await withTaskCancellationHandler {
      started.open()
      await release.wait()
    } onCancel: {
      cancels.withLock { $0 += 1 }
      cancelled.open()
    }
    if Task.isCancelled { throw .cancelled }
    return "\(samples.count)"
  }
}

/// The recording a test grows by hand, as the capture would.
final class GrowingRecording: Sendable {
  private let samples = Mutex<[Float]>([])

  func append(_ more: [Float]) { samples.withLock { $0 += more } }
  var soFar: [Float] { samples.withLock { $0 } }
}

struct ListeningTests {
  var engine = CountingTranscriber()
  let recording = GrowingRecording()
  let clock = TestClock()

  func runtime(
    engine: (any Transcriber)? = nil, listening: Bool = true
  ) async -> TranscriptionRuntime {
    let engine = engine ?? self.engine
    let clock = clock
    let runtime = TranscriptionRuntime(
      sleep: { await clock.sleep(for: $0) }, now: { clock.now },
      load: { _ throws(TranscriptionError) in engine })
    await runtime.activate(.parakeetV3)
    let recording = recording
    if listening {
      await runtime.warm(listening: { recording.soFar })
      await clock.sleepers(atLeast: 2)
    }
    return runtime
  }

  /// One pass of the listening loop: wakes it, then waits until it sleeps again beside the idle
  /// timer, which the clock never reaches.
  func listen(passes: Int = 1) async {
    for _ in 0..<passes {
      clock.advanceToNextDeadline()
      await clock.sleepers(atLeast: 2)
    }
  }

  @Test func `the release reuses what was transcribed at the pause`() async throws {
    let runtime = await runtime()
    recording.append(speech(2) + quiet(0.5))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar + quiet(0.3)) == "36800")
    #expect(engine.inputs == [36_800])
  }

  @Test func `speech after the pause is transcribed at the release`() async throws {
    let runtime = await runtime()
    recording.append(speech(2) + quiet(0.5))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar + speech(1)) == "56000")
    #expect(engine.inputs == [36_800, 56_000])
  }

  @Test mutating func `a call that failed at the pause runs again at the release`() async throws {
    engine = CountingTranscriber(failures: 1)
    let runtime = await runtime()
    recording.append(speech(2) + quiet(0.5))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar) == "36800")
    #expect(engine.inputs == [36_800, 36_800])
  }

  @Test func `nothing is transcribed while the user keeps talking`() async throws {
    let runtime = await runtime()
    recording.append(speech(3))
    await listen()
    #expect(engine.inputs.isEmpty)
    #expect(try await runtime.transcribe(recording.soFar) == "48000")
  }

  @Test func `a recording longer than the window waits for the release`() async throws {
    let runtime = await runtime()
    recording.append(speech(16) + quiet(0.5))
    await listen()
    #expect(engine.inputs.isEmpty)
    #expect(try await runtime.transcribe(recording.soFar) == "260800")
  }

  @Test mutating func `a long recording is transcribed in pieces while the user talks`() async throws {
    engine = CountingTranscriber(lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime()
    recording.append(speech(2.5) + quiet(0.5) + speech(1))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar) == "44000 20000")
    #expect(engine.inputs == [44_000, 20_000])
  }

  @Test mutating func `the release decodes only the tail`() async throws {
    engine = CountingTranscriber(lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime()
    recording.append(speech(2.5) + quiet(0.5) + speech(2.5) + quiet(0.5) + speech(1))
    await listen(passes: 2)

    #expect(try await runtime.transcribe(recording.soFar) == "44000 48000 20000")
    #expect(engine.inputs == [44_000, 48_000, 20_000])
  }

  @Test mutating func `the release reuses a tail transcribed at a pause`() async throws {
    engine = CountingTranscriber(lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime()
    recording.append(speech(1.5) + quiet(0.5))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar + quiet(0.3)) == "28800")
    #expect(engine.inputs == [28_800])
  }

  @Test mutating func `a piece that failed is decoded again at the release`() async throws {
    engine = CountingTranscriber(
      failures: 1, lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime()
    recording.append(speech(2.5) + quiet(0.5) + speech(1))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar) == "44000 20000")
    #expect(engine.inputs == [44_000, 44_000, 20_000])
  }

  @Test mutating func `the text is the same when the runtime never listened`() async throws {
    engine = CountingTranscriber(lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime(listening: false)

    #expect(try await runtime.transcribe(speech(2.5) + quiet(0.5) + speech(1)) == "44000 20000")
    #expect(engine.inputs == [44_000, 20_000])
  }

  @Test mutating func `a silent recording is no speech without an engine call`() async {
    engine = CountingTranscriber(lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime(listening: false)

    await #expect(throws: TranscriptionError.noSpeech) { try await runtime.transcribe(quiet(3)) }
    #expect(engine.inputs.isEmpty)
  }

  @Test mutating func `samples that differ from what a piece decoded are decoded again`()
    async throws
  {
    engine = CountingTranscriber(lookahead: .pieces(shortest: 2 * second, longest: 4 * second))
    let runtime = await runtime()
    recording.append(speech(2.5) + quiet(0.5) + speech(1))
    await listen()
    var changed = recording.soFar
    changed[0] = 0.2

    #expect(try await runtime.transcribe(changed) == "44000 20000")
    #expect(engine.inputs == [44_000, 44_000, 20_000])
  }

  @Test func `cancelling the dictation aborts the call in flight`() async {
    let held = HeldTranscriber()
    let runtime = await runtime(engine: held)
    recording.append(speech(2.5) + quiet(0.5) + speech(1))
    clock.advanceToNextDeadline()
    await held.started.wait()

    await runtime.coolDown()
    #expect(held.cancellations == 1)
    held.open()
    await runtime.shutDown()
  }

  @Test func `shut down waits for a piece in flight`() async {
    let held = HeldTranscriber()
    let runtime = await runtime(engine: held)
    recording.append(speech(2.5) + quiet(0.5) + speech(1))
    clock.advanceToNextDeadline()
    await held.started.wait()

    let finished = Mutex(false)
    let shutDown = Task {
      await runtime.shutDown()
      return finished.withLock { $0 }
    }
    await held.cancelled.wait()
    finished.withLock { $0 = true }
    held.open()
    #expect(await shutDown.value)
  }
}
