import Testing

@testable import DictationCore

private let press = HostTime(ticks: 1_000_000)
private let release = HostTime(ticks: 2_000_000)

struct DictationMachineTests {
  private func hello() throws -> Transcript { try #require(Transcript("hello")) }

  private func recording() throws -> (DictationMachine, SessionID) {
    var machine = DictationMachine()
    _ = machine.handle(.command(.pushToTalkStart, at: press))
    let id = try #require(machine.currentSession)
    _ = machine.handle(.captureStarted(id))
    return (machine, id)
  }

  private func transcribing() throws -> (DictationMachine, SessionID) {
    var (machine, id) = try recording()
    _ = machine.handle(.command(.pushToTalkStop, at: release))
    _ = machine.handle(.captureStopped(id, samples: [0.5]))
    return (machine, id)
  }

  private func pasting() throws -> (DictationMachine, SessionID) {
    var (machine, id) = try transcribing()
    _ = machine.handle(.transcribed(id, try hello()))
    _ = machine.handle(.processed(id, try hello()))
    return (machine, id)
  }

  @Test func `hold, speak and release pastes the transcript`() throws {
    var machine = DictationMachine()
    #expect(machine.phase == .idle)
    let start = machine.handle(.command(.pushToTalkStart, at: press))
    let id = try #require(machine.currentSession)
    #expect(start == [.startCapture(id, pressedAt: press)])
    #expect(machine.phase == .starting(.pushToTalk))
    #expect(machine.handle(.captureStarted(id)) == [.playCue(.start)])
    #expect(machine.phase == .recording(.pushToTalk))
    #expect(machine.handle(.command(.pushToTalkStop, at: release)) == [.stopCapture(id, releasedAt: release)])
    #expect(machine.phase == .stopping)
    #expect(
      machine.handle(.captureStopped(id, samples: [0.25])) == [
        .keepRecording(id, samples: [0.25]), .transcribe(id, samples: [0.25]),
      ])
    #expect(machine.phase == .transcribing)
    #expect(
      machine.handle(.transcribed(id, try hello())) == [.discardRecording(id), .process(id, try hello())])
    #expect(machine.phase == .transcribing)
    #expect(machine.handle(.processed(id, try hello())) == [.paste(id, try hello())])
    #expect(machine.phase == .pasting)
    let target = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
    let pastedAt = release.advanced(by: .milliseconds(200))
    let done = machine.handle(.pasted(id, target: target, at: pastedAt))
    #expect(
      done == [
        .latency(.releaseToPasted(pastedAt.duration(since: release))),
        .save(
          DictationEntry(
            session: id, mode: .pushToTalk, pressedAt: press,
            recordingDuration: release.duration(since: press),
            transcript: try hello(), target: target)),
        .endTerminalDisplay(id, after: .milliseconds(650)),
      ])
    #expect(machine.phase == .complete)
    #expect(machine.finishedSession?.target == target)
    #expect(machine.handle(.terminalDisplayEnded(id)) == [])
    #expect(machine.phase == .idle)
    #expect(machine.currentSession == nil)
  }

  @Test func `release before capture starts aborts and drops the late start`() throws {
    var machine = DictationMachine()
    _ = machine.handle(.command(.pushToTalkStart, at: press))
    let id = try #require(machine.currentSession)
    #expect(
      machine.handle(.command(.pushToTalkStop, at: release)) == [
        .cancelCapture(id), .playCue(.cancel), .endTerminalDisplay(id, after: .milliseconds(120)),
      ])
    #expect(machine.handle(.captureStarted(id)) == [])
    #expect(machine.phase == .failed(.aborted))
  }

  @Test func `cancel while transcribing aborts and drops the late transcript`() throws {
    var (machine, id) = try transcribing()
    #expect(
      machine.handle(.command(.cancel, at: release)) == [
        .playCue(.cancel), .discardRecording(id), .endTerminalDisplay(id, after: .milliseconds(120)),
      ])
    #expect(machine.phase == .failed(.aborted))
    #expect(machine.handle(.transcribed(id, try hello())) == [])
    #expect(machine.phase == .failed(.aborted))
  }

  @Test func `cancel while pasting is ignored and the paste completes`() throws {
    var (machine, id) = try pasting()
    #expect(machine.handle(.command(.cancel, at: release)) == [])
    #expect(machine.phase == .pasting)
    _ = machine.handle(.pasted(id, target: nil, at: release))
    #expect(machine.phase == .complete)
  }

  @Test func `a press while transcribing is ignored`() throws {
    var (machine, id) = try transcribing()
    #expect(machine.handle(.command(.pushToTalkStart, at: release)) == [])
    #expect(machine.handle(.command(.toggle, at: release)) == [])
    #expect(machine.currentSession == id)
    #expect(machine.phase == .transcribing)
  }

  @Test func `completions from an old session are dropped after a new one starts`() throws {
    var (machine, old) = try transcribing()
    _ = machine.handle(.command(.cancel, at: release))
    _ = machine.handle(.command(.pushToTalkStart, at: release))
    let new = try #require(machine.currentSession)
    #expect(new != old)
    #expect(machine.handle(.transcribed(old, try hello())) == [])
    #expect(machine.handle(.failed(old, .transcriptionError)) == [])
    #expect(machine.handle(.terminalDisplayEnded(old)) == [])
    #expect(machine.phase == .starting(.pushToTalk))
  }

  @Test func `a failed transcription shows its reason`() throws {
    var (machine, id) = try transcribing()
    #expect(
      machine.handle(.failed(id, .transcriptionError)) == [
        .failRecording(id, .transcriptionError), .playCue(.error),
        .endTerminalDisplay(id, after: .milliseconds(2900)),
      ])
    #expect(machine.phase == .failed(.transcriptionError))
  }

  @Test(arguments: [
    DictationFailureReason.captureError(.captureFailed), .captureError(.noInputDevice),
    .captureError(.startTimedOut), .microphonePermissionDenied,
  ])
  func `a capture start failure shows its reason`(reason: DictationFailureReason) throws {
    var machine = DictationMachine()
    _ = machine.handle(.command(.pushToTalkStart, at: press))
    let id = try #require(machine.currentSession)
    #expect(
      machine.handle(.failed(id, reason)) == [
        .playCue(.error), .endTerminalDisplay(id, after: .milliseconds(2900)),
      ])
    #expect(machine.phase == .failed(reason))
  }

  @Test func `the terminal display ends in idle`() throws {
    var (machine, id) = try pasting()
    _ = machine.handle(.failed(id, .pasteRuntimeError))
    #expect(machine.phase == .failed(.pasteRuntimeError))
    _ = machine.handle(.terminalDisplayEnded(id))
    #expect(machine.phase == .idle)
  }

  @Test func `a press during the terminal display starts a new session`() throws {
    var (machine, old) = try pasting()
    _ = machine.handle(.pasted(old, target: nil, at: release))
    let effects = machine.handle(.command(.toggle, at: release))
    let new = try #require(machine.currentSession)
    #expect(effects == [.startCapture(new, pressedAt: release)])
    #expect(machine.phase == .starting(.toggle))
    #expect(machine.handle(.terminalDisplayEnded(old)) == [])
    #expect(machine.phase == .starting(.toggle))
  }

  @Test func `paste-last before any dictation shows nothing to paste briefly`() throws {
    var machine = DictationMachine()
    let effects = machine.handle(.command(.pasteLast, at: press))
    let id = try #require(machine.currentSession)
    #expect(effects == [.playCue(.error), .endTerminalDisplay(id, after: .milliseconds(1100))])
    #expect(machine.phase == .failed(.nothingToPaste))
    #expect(machine.finishedSession == nil)
    #expect(machine.pressedAt == nil)
    _ = machine.handle(.terminalDisplayEnded(id))
    #expect(machine.phase == .idle)
  }

  @Test func `paste-last during the pasted flash re-pastes silently and records nothing`() throws {
    var (machine, old) = try pasting()
    _ = machine.handle(.pasted(old, target: nil, at: release))
    #expect(machine.phase == .complete)
    let effects = machine.handle(.command(.pasteLast, at: release))
    let id = try #require(machine.currentSession)
    #expect(id != old)
    #expect(effects == [.pasteLast(id, try hello())])
    #expect(machine.phase == .pasting)
    #expect(machine.finishedSession == nil)
    #expect(machine.handle(.command(.cancel, at: release)) == [])
    #expect(machine.handle(.terminalDisplayEnded(old)) == [])
    #expect(machine.handle(.pasted(id, target: nil, at: release)) == [])
    #expect(machine.phase == .idle)
    #expect(machine.finishedSession == nil)
  }

  @Test(arguments: [DictationFailureReason.pastePermissionDenied, .pasteRuntimeError])
  func `a failed paste-last shows its reason briefly`(reason: DictationFailureReason) throws {
    var (machine, old) = try pasting()
    _ = machine.handle(.pasted(old, target: nil, at: release))
    _ = machine.handle(.command(.pasteLast, at: release))
    let id = try #require(machine.currentSession)
    #expect(
      machine.handle(.failed(id, reason)) == [
        .playCue(.error), .endTerminalDisplay(id, after: .milliseconds(1100)),
      ])
    #expect(machine.phase == .failed(reason))
    #expect(machine.finishedSession == nil)
    _ = machine.handle(.terminalDisplayEnded(id))
    #expect(machine.phase == .idle)
  }

  @Test func `paste-last while recording is ignored`() throws {
    var (machine, id) = try recording()
    #expect(machine.handle(.command(.pasteLast, at: release)) == [])
    #expect(machine.phase == .recording(.pushToTalk))
    #expect(machine.currentSession == id)
  }

  @Test func `text whose paste failed can still be pasted with paste-last`() throws {
    var (machine, old) = try pasting()
    _ = machine.handle(.failed(old, .pasteRuntimeError))
    _ = machine.handle(.terminalDisplayEnded(old))
    let effects = machine.handle(.command(.pasteLast, at: release))
    let id = try #require(machine.currentSession)
    #expect(effects == [.pasteLast(id, try hello())])
  }

  @Test func `a second toggle before capture starts cancels at once`() throws {
    var machine = DictationMachine()
    _ = machine.handle(.command(.toggle, at: press))
    let id = try #require(machine.currentSession)
    #expect(
      machine.handle(.command(.toggle, at: release)) == [
        .cancelCapture(id), .playCue(.cancel), .endTerminalDisplay(id, after: .milliseconds(120)),
      ])
    #expect(machine.phase == .failed(.aborted))
  }

  @Test func `a push-to-talk press while starting is ignored`() throws {
    var machine = DictationMachine()
    _ = machine.handle(.command(.pushToTalkStart, at: press))
    let id = try #require(machine.currentSession)
    #expect(machine.handle(.command(.pushToTalkStart, at: release)) == [])
    #expect(machine.phase == .starting(.pushToTalk))
    #expect(machine.currentSession == id)
  }

  @Test func `the start cue plays once per session`() throws {
    var machine = DictationMachine()
    _ = machine.handle(.command(.pushToTalkStart, at: press))
    let id = try #require(machine.currentSession)
    #expect(machine.handle(.captureStarted(id)) == [.playCue(.start)])
    #expect(machine.handle(.captureStarted(id)) == [])
    _ = machine.handle(.command(.cancel, at: release))
    _ = machine.handle(.command(.pushToTalkStart, at: release))
    #expect(machine.handle(.captureStarted(id)) == [])
  }

  @Test(arguments: [
    DictationFailureReason.captureError(.deviceLost), .captureError(.stopTimedOut), .noSpeech,
    .pasteRuntimeError, .pastePermissionDenied,
  ])
  func `every failure but an abort plays the error cue`(reason: DictationFailureReason) throws {
    var (machine, id) = try recording()
    #expect(machine.handle(.failed(id, reason)).contains(.playCue(.error)))
  }

  @Test func `an abort and a completion play no error cue`() throws {
    var (machine, id) = try recording()
    #expect(!machine.handle(.failed(id, .aborted)).contains(.playCue(.error)))
    var (pasting, pasteID) = try pasting()
    let done = pasting.handle(.pasted(pasteID, target: nil, at: release))
    #expect(!done.contains { if case .playCue = $0 { true } else { false } })
  }

  @Test func `whitespace-only text is not a transcript`() {
    #expect(Transcript(" \n\t ") == nil)
    #expect(Transcript("  hi there \n")?.text == "hi there")
  }

  @Test func `a transcript never prints its text`() throws {
    let transcript = try #require(Transcript("secret words"))
    #expect(transcript.description == "Transcript(12 characters)")
    #expect(transcript.debugDescription == "Transcript(12 characters)")
    #expect(!"\(transcript)".contains("secret"))
  }

  private func entry(_ id: SessionID, target: TargetApp?) throws -> DictationEntry {
    DictationEntry(
      session: id, mode: .pushToTalk, pressedAt: press, recordingDuration: release.duration(since: press),
      transcript: try hello(), target: target)
  }

  private func saves(_ effects: [DictationEffect]) -> [DictationEntry] {
    effects.compactMap { if case .save(let entry) = $0 { entry } else { nil } }
  }

  @Test func `a completed dictation saves once with its target and duration`() throws {
    var (machine, id) = try pasting()
    let target = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
    #expect(
      saves(machine.handle(.pasted(id, target: target, at: release))) == [try entry(id, target: target)])
    #expect(saves(machine.handle(.terminalDisplayEnded(id))).isEmpty)
  }

  @Test func `a failed paste still saves the transcript without a target`() throws {
    var (machine, id) = try pasting()
    #expect(
      machine.handle(.failed(id, .pasteRuntimeError)) == [
        .save(try entry(id, target: nil)), .playCue(.error),
        .endTerminalDisplay(id, after: .milliseconds(2900)),
      ])
  }

  @Test func `cancel during recording saves nothing and keeps no audio`() throws {
    var (machine, id) = try recording()
    #expect(
      machine.handle(.command(.cancel, at: release)) == [
        .cancelCapture(id), .playCue(.cancel), .endTerminalDisplay(id, after: .milliseconds(120)),
      ])
  }

  @Test func `no speech fails the recording and saves nothing`() throws {
    var (machine, id) = try transcribing()
    #expect(
      machine.handle(.failed(id, .noSpeech)) == [
        .failRecording(id, .noSpeech), .playCue(.error), .endTerminalDisplay(id, after: .milliseconds(2900)),
      ])
  }

  @Test func `a transcript discards the kept recording`() throws {
    var (machine, id) = try transcribing()
    #expect(machine.handle(.transcribed(id, try hello())).first == .discardRecording(id))
  }

  @Test func `a stale transcript for an old session emits nothing`() throws {
    var (machine, old) = try transcribing()
    _ = machine.handle(.command(.cancel, at: release))
    _ = machine.handle(.command(.pushToTalkStart, at: release))
    #expect(machine.handle(.transcribed(old, try hello())) == [])
  }

  @Test func `paste-last never saves`() throws {
    var (machine, old) = try pasting()
    _ = machine.handle(.pasted(old, target: nil, at: release))
    _ = machine.handle(.command(.pasteLast, at: release))
    let id = try #require(machine.currentSession)
    #expect(saves(machine.handle(.pasted(id, target: nil, at: release))).isEmpty)
    _ = machine.handle(.command(.pasteLast, at: release))
    let failed = try #require(machine.currentSession)
    #expect(saves(machine.handle(.failed(failed, .pasteRuntimeError))).isEmpty)
  }

  private func awaitingManualPaste() throws -> (DictationMachine, SessionID) {
    var (machine, id) = try pasting()
    _ = machine.handle(.manualPasteNeeded(id, at: release))
    return (machine, id)
  }

  @Test func `a paste no text field took opens a 10 s window for the user's ⌘V`() throws {
    var (machine, id) = try pasting()
    #expect(
      machine.handle(.manualPasteNeeded(id, at: release)) == [.expireManualPaste(id, after: .seconds(10))])
    #expect(machine.phase == .awaitingManualPaste(until: release.advanced(by: .seconds(10))))
  }

  @Test func `the user's ⌘V completes the dictation without a latency mark`() throws {
    var (machine, id) = try awaitingManualPaste()
    #expect(machine.handle(.command(.manualPaste, at: release)) == [.completeManualPaste(id)])
    let target = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
    #expect(
      machine.handle(.pasted(id, target: target, at: release)) == [
        .save(try entry(id, target: target)), .endTerminalDisplay(id, after: .milliseconds(650)),
      ])
    #expect(machine.phase == .complete)
  }

  @Test func `an unused window expires quietly and keeps the transcript in history`() throws {
    var (machine, id) = try awaitingManualPaste()
    #expect(
      machine.handle(.manualPasteExpired(id)) == [
        .abandonManualPaste(id), .save(try entry(id, target: nil)),
        .endTerminalDisplay(id, after: .milliseconds(2900)),
      ])
    #expect(machine.phase == .failed(.manualPasteExpired))
  }

  @Test func `escape closes the window with the cancel cue`() throws {
    var (machine, id) = try awaitingManualPaste()
    #expect(
      machine.handle(.command(.cancel, at: release)) == [
        .abandonManualPaste(id), .playCue(.cancel), .save(try entry(id, target: nil)),
        .endTerminalDisplay(id, after: .milliseconds(120)),
      ])
    #expect(machine.phase == .failed(.aborted))
  }

  @Test func `a new press closes the window and starts recording at once`() throws {
    var (machine, old) = try awaitingManualPaste()
    let effects = machine.handle(.command(.pushToTalkStart, at: release))
    let id = try #require(machine.currentSession)
    #expect(
      effects == [
        .abandonManualPaste(old), .save(try entry(old, target: nil)), .startCapture(id, pressedAt: release),
      ])
    #expect(machine.phase == .starting(.pushToTalk))
  }

  @Test func `paste-last in the window closes it and pastes the same text`() throws {
    var (machine, old) = try awaitingManualPaste()
    let effects = machine.handle(.command(.pasteLast, at: release))
    let id = try #require(machine.currentSession)
    #expect(
      effects == [.abandonManualPaste(old), .save(try entry(old, target: nil)), .pasteLast(id, try hello())])
  }

  @Test func `a window that already closed ignores a late expiry or ⌘V`() throws {
    var (machine, id) = try awaitingManualPaste()
    _ = machine.handle(.command(.manualPaste, at: release))
    _ = machine.handle(.pasted(id, target: nil, at: release))
    #expect(machine.handle(.manualPasteExpired(id)) == [])
    #expect(machine.handle(.command(.manualPaste, at: release)) == [])
    #expect(machine.phase == .complete)
  }
}
