import AudioCapture
import DictationCore
import Paste
import Testing
import Transcription

@testable import Dictation

/// One-key push to talk through the real pipeline with fake services.
struct DictationPipelineHoldTests {
  private func services(
    _ commands: AsyncStream<StampedCommand>, cues: CueLog, pastes: PasteLog,
    sleep: @escaping @Sendable (Duration) async -> Void
  ) -> DictationServices {
    DictationServices(
      commands: commands, phaseDidChange: { _ in }, startCapture: { _, _ in }, stopCapture: { _ in [0.1] },
      cancelCapture: {}, transcribe: { _ in "hello" }, processor: .passThrough,
      paste: { transcript, _ in
        pastes.append(transcript.text)
        return .pasted(target: nil, at: HostTime(ticks: 300))
      },
      sleep: sleep, playCue: { cues.append($0) })
  }

  @Test func `an aborted hold leaves nothing behind`() async {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let cues = CueLog()
    let pastes = PasteLog()
    let never = Gate()
    let pipeline = DictationPipeline(
      services: services(commands, cues: cues, pastes: pastes, sleep: { _ in await never.wait() }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }

    keys.yield(StampedCommand(command: .holdStart(trial: false), at: HostTime(ticks: 100)))
    var seen: [DictationPhase] = []
    for await update in pipeline.updates {
      seen.append(update.phase)
      if update.phase == .recording(.pushToTalk) {
        keys.yield(StampedCommand(command: .holdAbort, at: HostTime(ticks: 200)))
      }
      if update.phase == .idle { break }
    }

    #expect(seen == [.starting(.pushToTalk), .recording(.pushToTalk), .idle])
    #expect(cues.recorded == [])
    #expect(pastes.recorded == [])
  }

  @Test func `a confirmed hold publishes the confirm and pastes on release`() async {
    let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
    let cues = CueLog()
    let pastes = PasteLog()
    let pipeline = DictationPipeline(
      services: services(commands, cues: cues, pastes: pastes, sleep: { _ in }))
    let runner = Task { await pipeline.run() }
    defer { runner.cancel() }

    keys.yield(StampedCommand(command: .holdStart(trial: false), at: HostTime(ticks: 100)))
    var confirmed: [DictationPhase] = []
    for await update in pipeline.updates {
      if update.hold?.isConfirmed == true, update.phase.showsRecording {
        confirmed.append(update.phase)
        if update.phase == .recording(.pushToTalk) {
          keys.yield(StampedCommand(command: .pushToTalkStop, at: HostTime(ticks: 200)))
        }
      }
      if update.phase == .idle { break }
    }

    #expect(confirmed.last == .recording(.pushToTalk))
    #expect(cues.recorded == [.start])
    #expect(pastes.recorded == ["hello"])
  }
}
