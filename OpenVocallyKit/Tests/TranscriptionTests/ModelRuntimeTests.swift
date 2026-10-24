import Foundation
import ModelsTestSupport
import Synchronization
import Testing

@testable import Models
@testable import Transcription

/// A sleep the test ends by hand, so the idle unload runs exactly when the test says.
final class ManualClock: Sendable {
  private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])

  var pending: Int { waiters.withLock { $0.count } }

  func sleep(_: Duration) async {
    await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
  }

  func fire() {
    let all = waiters.withLock { waiters in
      defer { waiters.removeAll() }
      return waiters
    }
    for waiter in all { waiter.resume() }
  }
}

func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
  for _ in 0..<10_000 where !(await condition()) { await Task.yield() }
}

struct TranscriptionRuntimeTests {
  let log = LoadLog()
  let clock = ManualClock()

  func runtime() -> TranscriptionRuntime {
    let log = log
    let clock = clock
    return TranscriptionRuntime(
      sleep: { await clock.sleep($0) }, load: { (model) throws(TranscriptionError) in try log.load(model) })
  }

  @Test func `activating loads the model once`() async throws {
    let runtime = runtime()
    await runtime.activate(.hosted(.parakeetV3))
    await runtime.activate(.hosted(.parakeetV3))
    #expect(try await runtime.transcribe([0]) == "text")
    #expect(log.loads == [.parakeetV3])
  }

  @Test func `no installed model fails with modelNotInstalled`() async {
    let runtime = runtime()
    await runtime.activate(nil)
    await #expect(throws: TranscriptionError.modelNotInstalled) { try await runtime.transcribe([0]) }
    #expect(log.loads.isEmpty)
  }

  @Test func `an idle model unloads and the next press loads it again`() async throws {
    let runtime = runtime()
    await runtime.activate(.hosted(.parakeetV3))
    _ = try await runtime.transcribe([0])
    await eventually { clock.pending == 2 }

    clock.fire()
    await eventually { await runtime.isLoaded == false }
    #expect(await runtime.isLoaded == false)

    await runtime.warm()
    _ = try await runtime.transcribe([0])
    #expect(log.loads == [.parakeetV3, .parakeetV3])
  }

  @Test func `a failed load is retried on the next dictation`() async throws {
    let runtime = runtime()
    log.fail(true)
    await runtime.activate(.hosted(.parakeetV3))
    await #expect(throws: TranscriptionError.engineFailed) { try await runtime.transcribe([0]) }

    log.fail(false)
    await eventually { await runtime.isLoaded == false }
    #expect(try await runtime.transcribe([0]) == "text")
  }

  @Test func `switching models loads the new one`() async throws {
    let runtime = runtime()
    await runtime.activate(.hosted(.parakeetV3))
    _ = try await runtime.transcribe([0])
    await runtime.activate(.hosted(.whisperTurbo))
    _ = try await runtime.transcribe([0])
    #expect(log.loads == [.parakeetV3, .whisperTurbo])
  }
}

struct TranscriptionRuntimeShutDownTests {
  @Test func `shutting down cancels a pending load and is safe to repeat`() async {
    let cancelled = Mutex(false)
    let runtime = TranscriptionRuntime(
      sleep: { _ in },
      load: { (_) throws(TranscriptionError) in
        try? await Task.sleep(for: .seconds(3600))
        cancelled.withLock { $0 = Task.isCancelled }
        throw .modelNotInstalled
      })
    await runtime.activate(.hosted(.parakeetV3))
    #expect(await runtime.isLoaded)
    await runtime.shutDown()
    await runtime.shutDown()
    #expect(await runtime.isLoaded == false)
    await eventually { cancelled.withLock { $0 } }
    #expect(cancelled.withLock { $0 })
  }

  @Test func `shutting down waits for an in-flight transcription and arms no idle timer`() async throws {
    let transcriber = GatedTranscriber()
    let clock = TestClock()
    let runtime = TranscriptionRuntime(
      sleep: { await clock.sleep(for: $0) }, now: { clock.now },
      load: { (_) throws(TranscriptionError) in transcriber })
    await runtime.activate(.hosted(.whisperTurbo))
    await clock.sleepers(atLeast: 1)
    let transcription = Task { try await runtime.transcribe([0]) }
    await transcriber.arrived.wait()
    let shutDown = Task {
      await runtime.shutDown()
      return transcriber.finished
    }
    // The shutdown cancels the idle timer first, so the transcription ends after it began.
    await clock.noSleepers()
    transcriber.open()
    #expect(await shutDown.value)
    #expect(try await transcription.value == "done")
    #expect(clock.sleepers(dueWithin: .seconds(20 * 60)) == 0)
  }

  @Test func `shutting down waits for a load that can't be interrupted`() async {
    let gate = Gate()
    let loadFinished = Mutex(false)
    let runtime = TranscriptionRuntime(
      sleep: { _ in },
      load: { (_) throws(TranscriptionError) in
        await gate.wait()
        loadFinished.withLock { $0 = true }
        return FakeTranscriber()
      })
    await runtime.activate(.hosted(.whisperTurbo))
    await eventually { gate.isWaiting }
    let shutDown = Task {
      await runtime.shutDown()
      return loadFinished.withLock { $0 }
    }
    gate.open()
    #expect(await shutDown.value)
    #expect(await runtime.isLoaded == false)
  }

  @Test func `after shutting down nothing loads and dictation is cancelled`() async {
    let log = LoadLog()
    let clock = ManualClock()
    let runtime = TranscriptionRuntime(
      sleep: { await clock.sleep($0) }, load: { (model) throws(TranscriptionError) in try log.load(model) })
    await runtime.activate(.hosted(.parakeetV3))
    await eventually { clock.pending == 1 }
    await runtime.shutDown()
    await runtime.warm()
    await runtime.activate(.hosted(.whisperTurbo))
    await #expect(throws: TranscriptionError.cancelled) { try await runtime.transcribe([0]) }
    #expect(log.loads == [.parakeetV3])
    #expect(await runtime.isLoaded == false)
    #expect(clock.pending == 1)
  }
}

/// A one-shot gate that ignores cancellation, like `whisper_init`.
final class Gate: Sendable {
  private let state = Mutex<(waiting: Bool, open: Bool, waiter: CheckedContinuation<Void, Never>?)>(
    (false, false, nil))

  var isWaiting: Bool { state.withLock { $0.waiting } }

  func wait() async {
    await withCheckedContinuation { waiter in
      let resumeNow = state.withLock { state in
        state.waiting = true
        if state.open { return true }
        state.waiter = waiter
        return false
      }
      if resumeNow { waiter.resume() }
    }
  }

  func open() {
    let waiter = state.withLock { state in
      state.open = true
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume()
  }
}

/// Blocks in `transcribe` until the test opens it.
final class GatedTranscriber: Transcriber {
  let arrived = Gate()
  private let release = Gate()
  private let done = Mutex(false)

  var finished: Bool { done.withLock { $0 } }

  func transcribe(_: [Float]) async throws(TranscriptionError) -> String {
    arrived.open()
    await release.wait()
    done.withLock { $0 = true }
    return "done"
  }

  func open() { release.open() }
}

/// Records keep-warm pings and transcriptions in order. A ping can be held open to stand in for
/// one still running on the Neural Engine.
final class PingLog: Sendable, Transcriber {
  private let state = Mutex<(events: [String], held: CheckedContinuation<Void, Never>?, holding: Bool)>(
    ([], nil, false))

  var events: [String] { state.withLock { $0.events } }
  var pings: Int { events.count(where: { $0 == "ping" }) }

  func holdNextPing() { state.withLock { $0.holding = true } }

  func releasePing() {
    let held = state.withLock { state in
      defer { state.held = nil }
      return state.held
    }
    held?.resume()
  }

  /// Opens once a ping is held.
  let holding = Gate()

  func keepWarm() async {
    let hold = state.withLock { state in
      state.events.append("ping")
      defer { state.holding = false }
      return state.holding
    }
    if hold {
      await withCheckedContinuation { continuation in
        state.withLock { $0.held = continuation }
        holding.open()
      }
    }
    state.withLock { $0.events.append("ping done") }
  }

  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    state.withLock { $0.events.append("transcribe") }
    return "text"
  }
}

struct KeepWarmTests {
  let pings = PingLog()
  let clock = TestClock()

  func runtime() -> TranscriptionRuntime {
    let pings = pings
    let clock = clock
    return TranscriptionRuntime(
      sleep: { await clock.sleep(for: $0) }, now: { clock.now },
      load: { _ throws(TranscriptionError) in pings })
  }

  /// Wakes the warm loop for one more ping and waits until it sleeps again beside the idle timer,
  /// which the clock never reaches.
  func ping() async {
    clock.advanceToNextDeadline()
    await clock.sleepers(atLeast: 2)
  }

  @Test func `warming pings the model until the transcription`() async throws {
    let runtime = runtime()
    await runtime.activate(.hosted(.parakeetV3))
    await runtime.warm()
    await clock.sleepers(atLeast: 2)
    await ping()
    await ping()
    #expect(pings.pings == 3)

    #expect(try await runtime.transcribe([0]) == "text")
    #expect(clock.sleepers(dueWithin: .seconds(1)) == 0)
    clock.advance(by: .seconds(1))
    await runtime.shutDown()
    #expect(pings.events == ["ping", "ping done", "ping", "ping done", "ping", "ping done", "transcribe"])
  }

  @Test func `a transcription starts without waiting for the ping still running`() async throws {
    let runtime = runtime()
    await runtime.activate(.hosted(.parakeetV3))
    pings.holdNextPing()
    await runtime.warm()
    await pings.holding.wait()
    #expect(try await runtime.transcribe([0]) == "text")
    #expect(Array(pings.events.suffix(2)) == ["ping", "transcribe"])

    pings.releasePing()
    await runtime.shutDown()
    #expect(pings.events.last == "ping done")
  }

  @Test func `cooling down stops the pings`() async throws {
    let runtime = runtime()
    await runtime.activate(.hosted(.parakeetV3))
    await runtime.warm()
    await clock.sleepers(atLeast: 2)
    #expect(pings.pings == 1)

    await runtime.coolDown()
    #expect(clock.sleepers(dueWithin: .seconds(1)) == 0)
    clock.advance(by: .seconds(1))
    await runtime.shutDown()
    #expect(pings.pings == 1)
  }
}
