import Models
import ModelsTestSupport
import Synchronization
import Testing

@testable import Transcription

/// Streams into a log: what each stream was given, how it ended, and any whole-recording calls.
final class StreamingTranscriber: Sendable, Transcriber {
  struct Log {
    var opened = 0
    var appended: [Int] = []
    var heard: [Float] = []
    var finished: [Int] = []
    var cancels = 0
    var whole: [Int] = []
  }

  let log = Mutex(Log())
  let failure: TranscriptionError?

  init(failure: TranscriptionError? = nil) {
    self.failure = failure
  }

  var record: Log { log.withLock { $0 } }

  func openStream() async throws(TranscriptionError) -> (any TranscriptionStream)? {
    log.withLock {
      $0.opened += 1
      $0.heard = []
    }
    return Stream(owner: self)
  }

  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    log.withLock { $0.whole.append(samples.count) }
    return "whole \(samples.count)"
  }

  struct Stream: TranscriptionStream {
    let owner: StreamingTranscriber

    func append(_ samples: ArraySlice<Float>) {
      owner.log.withLock {
        $0.appended.append(samples.count)
        $0.heard += samples
      }
    }

    func finish(_ rest: ArraySlice<Float>) async throws(TranscriptionError) -> String {
      let heard = owner.log.withLock {
        $0.finished.append(rest.count)
        $0.heard += rest
        return $0.heard.count
      }
      if let failure = owner.failure { throw failure }
      return "streamed \(heard)"
    }

    func cancel() async {
      owner.log.withLock { $0.cancels += 1 }
    }
  }
}

struct StreamingTests {
  let recording = GrowingRecording()
  let clock = TestClock()

  func runtime(_ engine: StreamingTranscriber) async -> TranscriptionRuntime {
    let clock = clock
    let runtime = TranscriptionRuntime(
      sleep: { await clock.sleep(for: $0) }, now: { clock.now },
      load: { _ throws(TranscriptionError) in engine })
    await runtime.activate(.hosted(.parakeetV3))
    let recording = recording
    await runtime.warm(listening: { recording.soFar })
    await clock.sleepers(atLeast: 2)
    return runtime
  }

  func listen() async {
    clock.advanceToNextDeadline()
    await clock.sleepers(atLeast: 2)
  }

  @Test func `the recording streams while it grows and the release only finishes it`() async throws {
    let engine = StreamingTranscriber()
    let runtime = await runtime(engine)
    recording.append(speech(1))
    await listen()
    recording.append(quiet(0.5))
    await listen()
    let final = recording.soFar + speech(0.25)

    #expect(try await runtime.transcribe(final) == "streamed 28000")
    let log = engine.record
    #expect(log.opened == 1)
    #expect(log.appended == [16_000, 8_000])
    #expect(log.finished == [4_000])
    #expect(log.heard == final)
    #expect(log.whole.isEmpty)
  }

  @Test func `a release that differs from what streamed is transcribed whole`() async throws {
    let engine = StreamingTranscriber()
    let runtime = await runtime(engine)
    recording.append(speech(1))
    await listen()

    #expect(try await runtime.transcribe(quiet(1.5)) == "whole 24000")
    #expect(engine.record.cancels == 1)
    #expect(engine.record.finished.isEmpty)
  }

  @Test func `a stream that fails is transcribed whole`() async throws {
    let engine = StreamingTranscriber(failure: .engineFailed)
    let runtime = await runtime(engine)
    recording.append(speech(1))
    await listen()

    #expect(try await runtime.transcribe(recording.soFar) == "whole 16000")
  }

  @Test func `no speech in the stream is no speech`() async {
    let engine = StreamingTranscriber(failure: .noSpeech)
    let runtime = await runtime(engine)
    recording.append(quiet(1))
    await listen()

    await #expect(throws: TranscriptionError.noSpeech) { try await runtime.transcribe(recording.soFar) }
    #expect(engine.record.whole.isEmpty)
  }

  @Test func `a cancelled dictation ends its stream and the next press opens another`() async throws {
    let engine = StreamingTranscriber()
    let runtime = await runtime(engine)
    recording.append(speech(1))
    await listen()
    await runtime.coolDown()
    await eventually { engine.record.cancels == 1 }
    #expect(engine.record.cancels == 1)

    let next = GrowingRecording()
    await runtime.warm(listening: { next.soFar })
    await clock.sleepers(atLeast: 2)
    next.append(speech(0.5))
    await listen()
    #expect(try await runtime.transcribe(next.soFar) == "streamed 8000")
    #expect(engine.record.opened == 2)
  }
}

struct StreamFeedTests {
  @Test func `each call gives only what was recorded since the last`() {
    var feed = StreamFeed()
    #expect(feed.next([]) == nil)
    #expect(feed.next([1, 2]) == [1, 2])
    #expect(feed.next([1, 2]) == nil)
    #expect(feed.next([1, 2, 3]) == [3])
    #expect(feed.fed == 3)
  }

  @Test func `the release owes the tail, or nothing when the recording changed`() {
    var feed = StreamFeed()
    _ = feed.next([1, 2, 3])
    #expect(feed.rest(of: [1, 2, 3, 4]) == [4])
    #expect(feed.rest(of: [1, 2, 3])?.isEmpty == true)
    #expect(feed.rest(of: [1, 2]) == nil)
    #expect(feed.rest(of: [1, 9, 3, 4]) == nil)
  }
}
