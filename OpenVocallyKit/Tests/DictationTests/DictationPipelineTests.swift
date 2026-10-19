import AudioCapture
import DictationCore
import Hotkeys
import Paste
import Synchronization
import Testing
import Transcription

@testable import Dictation

final class PhaseLog: Sendable {
  private let phases = Mutex<[DictationPhase]>([])
  var recorded: [DictationPhase] { phases.withLock { $0 } }
  func append(_ phase: DictationPhase) { phases.withLock { $0.append(phase) } }
}

final class CueLog: Sendable {
  private let cues = Mutex<[SoundCue]>([])
  var recorded: [SoundCue] { cues.withLock { $0 } }
  func append(_ cue: SoundCue) { cues.withLock { $0.append(cue) } }
}

final class PasteLog: Sendable {
  private let texts = Mutex<[String]>([])
  var recorded: [String] { texts.withLock { $0 } }
  func append(_ text: String) { texts.withLock { $0.append(text) } }
}

final class CallLog: Sendable {
  private let calls = Mutex<[String]>([])
  private let running = Mutex((now: 0, peak: 0))
  var recorded: [String] { calls.withLock { $0 } }
  var peakConcurrency: Int { running.withLock { $0.peak } }
  func append(_ call: String) { calls.withLock { $0.append(call) } }
  func enter() {
    running.withLock {
      $0.now += 1
      $0.peak = max($0.peak, $0.now)
    }
  }
  func leave() { running.withLock { $0.now -= 1 } }
}

/// Holds a fake service call until the test opens it.
final class Gate: Sendable {
  private let opened: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() { (opened, continuation) = AsyncStream.makeStream() }
  func wait() async { for await _ in opened { return } }
  func open() { continuation.finish() }
}

private func fakeServices(
  commands: AsyncStream<StampedCommand>,
  startCapture:
    @escaping @Sendable (HostTime, @escaping @Sendable (CaptureError) -> Void) async throws(CaptureError) ->
    Void = { _, _ in },
  stopCapture: @escaping @Sendable (HostTime) async throws(CaptureError) -> [Float] = { _ in [0.1, 0.2] },
  cancelCapture: @escaping @Sendable () async -> Void = {},
  transcribe: @escaping @Sendable ([Float]) async throws(TranscriptionError) -> String = { _ in "hi" },
  paste: @escaping @Sendable (Transcript, PasteKind) async -> PasteOutcome = { _, _ in
    .pasted(target: nil, at: HostTime(ticks: 300))
  },
  playCue: @escaping @Sendable (SoundCue) -> Void = { _ in }
) -> DictationServices {
  DictationServices(
    commands: commands, phaseDidChange: { _ in }, startCapture: startCapture,
    stopCapture: stopCapture, cancelCapture: cancelCapture, transcribe: transcribe,
    processor: .passThrough, paste: paste, sleep: { _ in }, playCue: playCue)
}

private func press(_ ticks: UInt64) -> StampedCommand {
  StampedCommand(command: .pushToTalkStart, at: HostTime(ticks: ticks))
}

private func release(_ ticks: UInt64) -> StampedCommand {
  StampedCommand(command: .pushToTalkStop, at: HostTime(ticks: ticks))
}

private let escape = StampedCommand(command: .cancel, at: HostTime(ticks: 1))

extension AsyncStream<DictationUpdate>.Iterator {
  /// Drops updates until one in `phase` arrives.
  mutating func skip(to phase: DictationPhase) async -> DictationUpdate? {
    while let update = await next(isolation: #isolation) {
      if update.phase == phase { return update }
    }
    return nil
  }
}

struct DictationPipelineTests {
  @Test func `a sent toggle starts and a second one stops and pastes`() async throws {
    let (commands, _) = AsyncStream<StampedCommand>.makeStream()
    let pastes = PasteLog()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        paste: { transcript, _ in
          pastes.append(transcript.text)
          return .pasted(target: nil, at: HostTime(ticks: 300))
        }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }

    pipeline.send(.toggle)
    var seen: [DictationPhase] = []
    for await update in pipeline.updates {
      seen.append(update.phase)
      if update.phase == .recording(.toggle) { pipeline.send(.toggle) }
      if update.phase == .idle { break }
    }

    #expect(
      seen == [.starting(.toggle), .recording(.toggle), .stopping, .transcribing, .pasting, .complete, .idle])
    #expect(pastes.recorded == ["hi"])
  }

  @Test func `hold, speak and release pastes the transcribed text`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let phases = PhaseLog()
    let pastes = PasteLog()
    let pressedAt = HostTime(ticks: 100)
    let releasedAt = HostTime(ticks: 200)
    let services = DictationServices(
      commands: commands,
      phaseDidChange: { phases.append($0) },
      startCapture: { _, _ in },
      stopCapture: { _ in [0.1, 0.2] },
      cancelCapture: {},
      transcribe: { _ in "  hello world " },
      processor: .passThrough,
      paste: { transcript, _ in
        pastes.append(transcript.text)
        return .pasted(target: nil, at: HostTime(ticks: 300))
      },
      sleep: { _ in }
    )
    let pipeline = DictationPipeline(services: services)
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }

    keys.yield(StampedCommand(command: .pushToTalkStart, at: pressedAt))
    var seen: [DictationPhase] = []
    for await update in pipeline.updates {
      seen.append(update.phase)
      if update.phase == .recording(.pushToTalk) {
        keys.yield(StampedCommand(command: .pushToTalkStop, at: releasedAt))
      }
      if update.phase == .idle { break }
    }

    let expected: [DictationPhase] = [
      .starting(.pushToTalk), .recording(.pushToTalk), .stopping, .transcribing, .pasting, .complete, .idle,
    ]
    #expect(seen == expected)
    #expect(phases.recorded == expected)
    #expect(pastes.recorded == ["hello world"])
  }

  @Test func `a cancel behind a slow start never reaches the next session's recording`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let calls = CallLog()
    let slowStart = Gate()
    let starts = Mutex(0)
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        startCapture: { _, _ in
          let n = starts.withLock {
            $0 += 1
            return $0
          }
          calls.append("start \(n)")
          if n == 1 { await slowStart.wait() }
          calls.append("started \(n)")
        },
        cancelCapture: { calls.append("cancel") }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    let first = await updates.skip(to: .starting(.pushToTalk))
    keys.yield(escape)
    _ = await updates.skip(to: .idle)
    keys.yield(press(200))
    let second = await updates.skip(to: .starting(.pushToTalk))
    slowStart.open()
    let recording = await updates.skip(to: .recording(.pushToTalk))

    #expect(first?.session != second?.session)
    #expect(recording?.session == second?.session)
    #expect(calls.recorded == ["start 1", "started 1", "cancel", "start 2", "started 2"])
  }

  @Test func `a cancelled transcription never overlaps the next and its text is dropped`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let calls = CallLog()
    let slowFirst = Gate()
    let transcriptions = Mutex(0)
    let pastes = PasteLog()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        transcribe: { _ in
          let n = transcriptions.withLock {
            $0 += 1
            return $0
          }
          calls.enter()
          defer { calls.leave() }
          if n == 1 { await slowFirst.wait() }
          return "text \(n)"
        },
        paste: { transcript, _ in
          pastes.append(transcript.text)
          return .pasted(target: nil, at: HostTime(ticks: 900))
        }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(110))
    _ = await updates.skip(to: .transcribing)
    keys.yield(escape)
    _ = await updates.skip(to: .idle)
    keys.yield(press(200))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(210))
    _ = await updates.skip(to: .transcribing)
    slowFirst.open()
    _ = await updates.skip(to: .complete)

    #expect(pastes.recorded == ["text 2"])
    #expect(calls.peakConcurrency == 1)
  }

  @Test(arguments: [TranscriptionError.noSpeech, nil])
  func `silence ends as no speech, not a transcription error`(thrown: TranscriptionError?) async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        transcribe: { (_) throws(TranscriptionError) in
          if let thrown { throw thrown }
          return "   "
        }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(110))
    #expect(await updates.skip(to: .failed(.noSpeech)) != nil)
  }

  @Test func `a missing model says to download one`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands, transcribe: { (_) throws(TranscriptionError) in throw .modelNotInstalled }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(110))
    #expect(await updates.skip(to: .failed(.modelNotInstalled)) != nil)
  }

  @Test func `paste-last re-pastes the last transcript as a paste-last paste`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let kinds = Mutex<[PasteKind]>([])
    let pastes = PasteLog()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        paste: { transcript, kind in
          kinds.withLock { $0.append(kind) }
          pastes.append(transcript.text)
          return .pasted(target: nil, at: HostTime(ticks: 300))
        }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(110))
    _ = await updates.skip(to: .complete)
    keys.yield(StampedCommand(command: .pasteLast, at: HostTime(ticks: 400)))
    _ = await updates.skip(to: .pasting)
    #expect(await updates.skip(to: .idle) != nil)

    #expect(kinds.withLock { $0 } == [.dictation, .pasteLast])
    #expect(pastes.recorded == ["hi", "hi"])
  }

  @Test func `paste-last with nothing dictated shows nothing to paste`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let pastes = PasteLog()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        paste: { transcript, _ in
          pastes.append(transcript.text)
          return .pasted(target: nil, at: HostTime(ticks: 300))
        }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(StampedCommand(command: .pasteLast, at: HostTime(ticks: 100)))
    #expect(await updates.skip(to: .failed(.nothingToPaste)) != nil)
    #expect(await updates.skip(to: .idle) != nil)
    #expect(pastes.recorded.isEmpty)
  }

  @Test func `the start cue plays once after capture starts`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let cues = CueLog()
    let pipeline = DictationPipeline(services: fakeServices(commands: commands, playCue: { cues.append($0) }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(110))
    _ = await updates.skip(to: .idle)

    #expect(cues.recorded == [.start])
  }

  @Test func `a stop timeout fails the session and plays the error cue`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let cues = CueLog()
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands, stopCapture: { (_) throws(CaptureError) in throw .stopTimedOut },
        playCue: { cues.append($0) }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(110))
    #expect(await updates.skip(to: .failed(.captureError(.stopTimedOut))) != nil)
    _ = await updates.skip(to: .idle)

    #expect(cues.recorded == [.start, .error])
  }

  @Test func `a mic lost mid-recording fails the session as disconnected`() async throws {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let cues = CueLog()
    let interrupt = Mutex<(@Sendable (CaptureError) -> Void)?>(nil)
    let pipeline = DictationPipeline(
      services: fakeServices(
        commands: commands,
        startCapture: { _, onInterrupted in interrupt.withLock { $0 = onInterrupted } },
        playCue: { cues.append($0) }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    let onInterrupted = try #require(interrupt.withLock { $0 })
    onInterrupted(.deviceLost)
    #expect(await updates.skip(to: .failed(.captureError(.deviceLost))) != nil)
    _ = await updates.skip(to: .idle)

    #expect(cues.recorded == [.start, .error])
  }

  private func recordingServices(
    commands: AsyncStream<StampedCommand>, calls: CallLog, saved: PasteLog,
    transcribe: @escaping @Sendable ([Float]) async throws(TranscriptionError) -> String = { _ in
      "hello"
    },
    keepGate: Gate? = nil
  ) -> DictationServices {
    DictationServices(
      commands: commands, phaseDidChange: { _ in }, startCapture: { _, _ in }, stopCapture: { _ in [0.1] },
      cancelCapture: {},
      transcribe: { (samples) throws(TranscriptionError) in
        calls.append("transcribe")
        return try await transcribe(samples)
      },
      processor: .passThrough, paste: { _, _ in .pasted(target: nil, at: HostTime(ticks: 300)) },
      sleep: { _ in },
      save: { saved.append($0.transcript.text) },
      recordings: RecordingSink(
        keep: { _, _ in
          calls.append("keep")
          await keepGate?.wait()
          calls.append("kept")
        },
        discard: { _ in calls.append("discard") },
        fail: { _, reason in calls.append("fail \(reason)") }))
  }

  private func dictate(_ pipeline: DictationPipeline, _ keys: AsyncStream<StampedCommand>.Continuation)
    async
  {
    keys.yield(press(100))
    var updates = pipeline.updates.makeAsyncIterator()
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(200))
    _ = await updates.skip(to: .idle)
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func `a successful dictation keeps then discards its audio and saves once`() async {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let calls = CallLog()
    let saved = PasteLog()
    let pipeline = DictationPipeline(
      services: recordingServices(commands: commands, calls: calls, saved: saved))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }

    await dictate(pipeline, keys)
    await waitUntil { calls.recorded.contains("discard") && !saved.recorded.isEmpty }

    #expect(calls.recorded.filter { $0 != "transcribe" } == ["keep", "kept", "discard"])
    #expect(saved.recorded == ["hello"])
  }

  @Test func `a recording with no speech keeps then fails its audio and saves nothing`() async {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let calls = CallLog()
    let saved = PasteLog()
    let services = recordingServices(
      commands: commands, calls: calls, saved: saved,
      transcribe: { (_) throws(TranscriptionError) in throw .noSpeech })
    let pipeline = DictationPipeline(services: services)
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }

    await dictate(pipeline, keys)
    await waitUntil { calls.recorded.contains("fail noSpeech") }

    #expect(calls.recorded.filter { $0 != "transcribe" } == ["keep", "kept", "fail noSpeech"])
    #expect(saved.recorded.isEmpty)
  }

  @Test func `a slow audio write does not delay the transcription`() async {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let calls = CallLog()
    let saved = PasteLog()
    let write = Gate()
    let services = recordingServices(commands: commands, calls: calls, saved: saved, keepGate: write)
    let pipeline = DictationPipeline(services: services)
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }
    var updates = pipeline.updates.makeAsyncIterator()

    keys.yield(press(100))
    _ = await updates.skip(to: .recording(.pushToTalk))
    keys.yield(release(200))
    await waitUntil { calls.recorded.contains("transcribe") }
    #expect(Set(calls.recorded) == ["keep", "transcribe"])

    write.open()
    await waitUntil { calls.recorded.contains("discard") }
    #expect(Array(calls.recorded.suffix(2)) == ["kept", "discard"])
  }

  final class TapMatcher: Sendable {
    let state = Mutex(HotkeyMatcher(bindings: .defaults))
  }

  enum ManualPasteExit: CaseIterable {
    case pasted, expired, escape, copiedOver, newPress
  }

  /// The pipeline with a real matcher on its phase changes, so a test can press ⌘V as the tap would.
  private final class ManualPasteRig: Sendable {
    let pipeline: DictationPipeline
    let keys: AsyncStream<StampedCommand>.Continuation
    let matcher: TapMatcher
    let calls: CallLog
    let expiry: Gate

    init(completeResult: ManualPasteResult) {
      let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
      let matcher = TapMatcher()
      let calls = CallLog()
      let expiry = Gate()
      pipeline = DictationPipeline(
        services: DictationServices(
          commands: commands,
          phaseDidChange: { phase in matcher.state.withLock { $0.phaseDidChange(to: phase) } },
          startCapture: { _, _ in }, stopCapture: { _ in [0.1] }, cancelCapture: {},
          transcribe: { _ in "hello" }, processor: .passThrough,
          paste: { _, _ in .needsManualPaste },
          completeManualPaste: {
            calls.append("complete")
            return completeResult
          },
          abandonManualPaste: { calls.append("abandon") },
          sleep: { duration in if duration == DictationMachine.manualPasteWindow { await expiry.wait() } }))
      self.keys = keys
      self.matcher = matcher
      self.calls = calls
      self.expiry = expiry
    }

    /// What the tap does with a ⌘V key-down: its verdict, and the command it hands the pipeline.
    func pressCommandV() -> Verdict {
      let verdict = matcher.state.withLock { $0.handle(.down(.v, [.command]), at: HostTime(ticks: 300)) }
      _ = matcher.state.withLock { $0.handle(.up(.v, [.command]), at: HostTime(ticks: 300)) }
      for command in verdict.emits {
        keys.yield(StampedCommand(command: command, at: HostTime(ticks: 300)))
      }
      return verdict
    }

    func dictateIntoManualPaste() async -> AsyncStream<DictationUpdate>.Iterator {
      var updates = pipeline.updates.makeAsyncIterator()
      keys.yield(press(100))
      _ = await updates.skip(to: .recording(.pushToTalk))
      keys.yield(release(200))
      while let update = await updates.next() {
        if case .awaitingManualPaste = update.phase { break }
      }
      return updates
    }
  }

  @Test(arguments: ManualPasteExit.allCases)
  func `the ⌘V watcher is removed on every way out of the manual paste window`(exit: ManualPasteExit) async {
    let rig = ManualPasteRig(completeResult: exit == .copiedOver ? .ended : .pasted(target: nil))
    let runner = Task { await rig.pipeline.run() }
    defer { runner.cancel() }
    var updates = await rig.dictateIntoManualPaste()

    let final: DictationPhase
    switch exit {
    case .pasted:
      #expect(rig.pressCommandV() == Verdict(.pass, emit: .manualPaste))
      final = .complete
    case .expired:
      rig.expiry.open()
      final = .failed(.manualPasteExpired)
    case .escape:
      rig.keys.yield(escape)
      final = .failed(.aborted)
    case .copiedOver:
      #expect(rig.pressCommandV() == Verdict(.pass, emit: .manualPaste))
      final = .failed(.manualPasteExpired)
    case .newPress:
      rig.keys.yield(press(400))
      final = .starting(.pushToTalk)
    }
    #expect(await updates.skip(to: final) != nil)
    #expect(rig.pressCommandV() == .pass)
    let expected = exit == .pasted ? 0 : 1
    let abandons = { rig.calls.recorded.filter { $0 == "abandon" }.count }
    await waitUntil { abandons() == expected }
    #expect(abandons() == expected)
  }

  @Test func `a ⌘V outside a text field keeps the window and the watcher open`() async {
    let rig = ManualPasteRig(completeResult: .notInTextField)
    let runner = Task { await rig.pipeline.run() }
    defer { runner.cancel() }
    _ = await rig.dictateIntoManualPaste()

    #expect(rig.pressCommandV() == Verdict(.pass, emit: .manualPaste))
    await waitUntil { rig.calls.recorded == ["complete"] }
    #expect(rig.pressCommandV() == Verdict(.pass, emit: .manualPaste))
    await waitUntil { rig.calls.recorded == ["complete", "complete"] }
    #expect(rig.calls.recorded == ["complete", "complete"])
  }
}
