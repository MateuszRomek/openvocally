import Testing

@testable import DictationCore

private func at(_ ms: UInt64) -> HostTime { HostTime(nanoseconds: ms * 1_000_000) }

/// One-key push to talk in the machine: the cue waits for the confirm, an abort is silent,
/// and Try it never pastes or saves.
struct DictationMachineHoldTests {
  private func hello() throws -> Transcript { try #require(Transcript("hello")) }

  private func started(trial: Bool = false) throws -> (DictationMachine, SessionID) {
    var machine = DictationMachine()
    _ = machine.handle(.command(.holdStart(trial: trial), at: at(0)))
    return (machine, try #require(machine.currentSession))
  }

  @Test func `hold start schedules the confirm`() throws {
    var machine = DictationMachine()
    let effects = machine.handle(.command(.holdStart(trial: false), at: at(0)))
    let id = try #require(machine.currentSession)
    #expect(effects == [.startCapture(id, pressedAt: at(0)), .confirmHold(id, at: at(150))])
    #expect(machine.phase == .starting(.pushToTalk))
    #expect(machine.hold == Hold(isConfirmed: false, isTrial: false))
  }

  @Test func `no cue before the confirm`() throws {
    var (machine, id) = try started()
    #expect(machine.handle(.captureStarted(id)) == [])
    #expect(machine.phase == .recording(.pushToTalk))
  }

  @Test func `the cue plays at the confirm when the mic is open`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.captureStarted(id))
    #expect(machine.handle(.holdConfirmed(id)) == [.playCue(.start)])
    #expect(machine.hold == Hold(isConfirmed: true, isTrial: false))
  }

  @Test func `the cue plays at mic open when already confirmed`() throws {
    var (machine, id) = try started()
    #expect(machine.handle(.holdConfirmed(id)) == [])
    #expect(machine.handle(.captureStarted(id)) == [.playCue(.start)])
  }

  @Test func `the cue plays exactly once in either order`() throws {
    var (first, firstID) = try started()
    let micFirst =
      first.handle(.captureStarted(firstID)) + first.handle(.holdConfirmed(firstID))
      + first.handle(.holdConfirmed(firstID))
    var (second, secondID) = try started()
    let confirmFirst =
      second.handle(.holdConfirmed(secondID)) + second.handle(.captureStarted(secondID))
      + second.handle(.holdConfirmed(secondID))
    #expect(micFirst == [.playCue(.start)])
    #expect(confirmFirst == [.playCue(.start)])
  }

  @Test func `an abort is silent`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.captureStarted(id))
    #expect(machine.handle(.command(.holdAbort, at: at(80))) == [.cancelCapture(id)])
    #expect(machine.phase == .idle)
    #expect(machine.finishedSession == nil)
    #expect(machine.hold == nil)
  }

  @Test func `an abort after the confirm is silent`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.captureStarted(id))
    _ = machine.handle(.holdConfirmed(id))
    #expect(machine.handle(.command(.holdAbort, at: at(2000))) == [.cancelCapture(id)])
    #expect(machine.phase == .idle)
  }

  @Test func `a stale confirm is ignored`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.command(.holdAbort, at: at(50)))
    #expect(machine.handle(.holdConfirmed(id)) == [])
    #expect(machine.phase == .idle)
  }

  @Test func `a tap shorter than the confirm is silent`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.captureStarted(id))
    #expect(machine.handle(.command(.pushToTalkStop, at: at(60))) == [.cancelCapture(id)])
    #expect(machine.phase == .idle)
    #expect(machine.finishedSession == nil)
  }

  @Test func `a tap before the mic opens is silent`() throws {
    var (machine, id) = try started()
    #expect(machine.handle(.command(.pushToTalkStop, at: at(60))) == [.cancelCapture(id)])
    #expect(machine.phase == .idle)
  }

  @Test func `a confirmed release while starting cancels as a chord does`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.holdConfirmed(id))
    let effects = machine.handle(.command(.pushToTalkStop, at: at(400)))
    #expect(effects.prefix(2) == [.cancelCapture(id), .playCue(.cancel)])
    #expect(machine.phase == .failed(.aborted))
  }

  @Test func `a confirmed release stops and pastes`() throws {
    var (machine, id) = try started()
    _ = machine.handle(.captureStarted(id))
    _ = machine.handle(.holdConfirmed(id))
    #expect(machine.handle(.command(.pushToTalkStop, at: at(900))) == [.stopCapture(id, releasedAt: at(900))])
    _ = machine.handle(.captureStopped(id, samples: [0.5]))
    _ = machine.handle(.transcribed(id, try hello()))
    #expect(machine.handle(.processed(id, try hello())) == [.paste(id, try hello())])
  }

  @Test func `a hold is ignored during manual paste`() throws {
    var machine = DictationMachine()
    _ = machine.handle(.command(.pushToTalkStart, at: at(0)))
    let id = try #require(machine.currentSession)
    _ = machine.handle(.captureStarted(id))
    _ = machine.handle(.command(.pushToTalkStop, at: at(500)))
    _ = machine.handle(.captureStopped(id, samples: [0.5]))
    _ = machine.handle(.transcribed(id, try hello()))
    _ = machine.handle(.processed(id, try hello()))
    _ = machine.handle(.manualPasteNeeded(id, at: at(700)))
    #expect(machine.handle(.command(.holdStart(trial: false), at: at(800))) == [])
    #expect(machine.phase == .awaitingManualPaste(until: at(10_700)))
  }

  @Test func `a chord start has no confirm`() throws {
    var machine = DictationMachine()
    let effects = machine.handle(.command(.pushToTalkStart, at: at(0)))
    let id = try #require(machine.currentSession)
    #expect(effects == [.startCapture(id, pressedAt: at(0))])
    #expect(machine.hold == nil)
    #expect(machine.handle(.captureStarted(id)) == [.playCue(.start)])
  }

  @Test func `a trial never pastes or saves`() throws {
    var (machine, id) = try started(trial: true)
    var effects = machine.handle(.captureStarted(id))
    effects += machine.handle(.holdConfirmed(id))
    effects += machine.handle(.command(.pushToTalkStop, at: at(900)))
    effects += machine.handle(.captureStopped(id, samples: [0.5]))
    effects += machine.handle(.transcribed(id, try hello()))
    effects += machine.handle(.processed(id, try hello()))
    let kept = effects.filter { effect in
      switch effect {
      case .keepRecording, .discardRecording, .failRecording, .paste, .save, .abandonManualPaste: true
      default: false
      }
    }
    #expect(kept == [])
    #expect(machine.trialResult == .heard(try hello()))
    #expect(machine.phase == .complete)
    #expect(machine.hold == Hold(isConfirmed: true, isTrial: true))
  }

  @Test func `a trial with no speech reports it`() throws {
    var (machine, id) = try started(trial: true)
    _ = machine.handle(.captureStarted(id))
    _ = machine.handle(.holdConfirmed(id))
    _ = machine.handle(.command(.pushToTalkStop, at: at(900)))
    _ = machine.handle(.captureStopped(id, samples: [0.5]))
    let effects = machine.handle(.failed(id, .noSpeech))
    #expect(!effects.contains(.failRecording(id, .noSpeech)))
    #expect(machine.trialResult == .failed(.noSpeech))
  }

  @Test func `a trial does not become the paste-last text`() throws {
    var (machine, id) = try started(trial: true)
    _ = machine.handle(.captureStarted(id))
    _ = machine.handle(.holdConfirmed(id))
    _ = machine.handle(.command(.pushToTalkStop, at: at(900)))
    _ = machine.handle(.captureStopped(id, samples: [0.5]))
    _ = machine.handle(.transcribed(id, try hello()))
    _ = machine.handle(.processed(id, try hello()))
    _ = machine.handle(.terminalDisplayEnded(id))
    let effects = machine.handle(.command(.pasteLast, at: at(2000)))
    #expect(effects.first == .playCue(.error))
    #expect(machine.phase == .failed(.nothingToPaste))
  }

  @Test func `hold intents`() {
    #expect(
      DictationPhase.idle.intent(for: .holdStart(trial: true))
        == .start(.pushToTalk, hold: Hold(isConfirmed: false, isTrial: true)))
    #expect(DictationPhase.recording(.pushToTalk).intent(for: .holdStart(trial: false)) == .ignore)
    #expect(DictationPhase.starting(.pushToTalk).intent(for: .holdAbort) == .discard)
    #expect(DictationPhase.recording(.pushToTalk).intent(for: .holdAbort) == .discard)
    #expect(DictationPhase.recording(.toggle).intent(for: .holdAbort) == .ignore)
    #expect(DictationPhase.transcribing.intent(for: .holdAbort) == .ignore)
  }
}
