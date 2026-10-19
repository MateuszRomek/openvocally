import Testing

@testable import DictationCore

struct DictationIntentTests {
  @Test func cancelDuringTranscriptionCancelsTheTranscription() {
    #expect(DictationPhase.transcribing.intent(for: .cancel) == .cancelTranscription)
  }

  @Test(arguments: [
    (DictationPhase.idle, DictationIntent.ignore),
    (.awaitingManualPaste(until: HostTime(ticks: 1)), .cancelManualPaste),
    (.starting(.toggle), .cancel),
    (.recording(.toggle), .cancel),
    (.stopping, .cancel),
    (.pasting, .ignore),
    (.complete, .ignore),
    (.failed(.captureError(.captureFailed)), .ignore),
  ])
  func cancelIsScopedToTheActiveSession(phase: DictationPhase, expected: DictationIntent) {
    #expect(phase.intent(for: .cancel) == expected)
  }

  @Test func newPressInterruptsTheCompleteOrFailedDisplay() {
    #expect(DictationPhase.failed(.aborted).intent(for: .pushToTalkStart) == .start(.pushToTalk))
    #expect(DictationPhase.complete.intent(for: .toggle) == .start(.toggle))
    #expect(DictationPhase.transcribing.intent(for: .pushToTalkStart) == .ignore)
    #expect(DictationPhase.pasting.intent(for: .pushToTalkStart) == .ignore)
  }

  @Test(arguments: [
    (DictationPhase.idle, DictationIntent.start(.toggle)),
    (.starting(.toggle), .cancel),
    (.recording(.toggle), .stop),
    (.starting(.pushToTalk), .ignore),
    (.recording(.pushToTalk), .ignore),
    (.stopping, .ignore),
    (.transcribing, .ignore),
    (.pasting, .ignore),
    (.awaitingManualPaste(until: HostTime(ticks: 1)), .start(.toggle)),
  ])
  func toggle(phase: DictationPhase, expected: DictationIntent) {
    #expect(phase.intent(for: .toggle) == expected)
  }

  @Test(arguments: [
    (DictationPhase.starting(.pushToTalk), DictationIntent.cancel),
    (.recording(.pushToTalk), .stop),
    (.starting(.toggle), .ignore),
    (.recording(.toggle), .ignore),
    (.idle, .ignore),
    (.transcribing, .ignore),
  ])
  func pushToTalkRelease(phase: DictationPhase, expected: DictationIntent) {
    #expect(phase.intent(for: .pushToTalkStop) == expected)
  }

  @Test(arguments: [
    (DictationPhase.idle, DictationIntent.pasteLast),
    (.complete, .pasteLast),
    (.failed(.noSpeech), .pasteLast),
    (.starting(.toggle), .ignore),
    (.recording(.pushToTalk), .ignore),
    (.stopping, .ignore),
    (.transcribing, .ignore),
    (.pasting, .ignore),
    (.awaitingManualPaste(until: HostTime(ticks: 1)), .pasteLast),
  ])
  func pasteLastRunsOnlyWhenASessionCouldStart(phase: DictationPhase, expected: DictationIntent) {
    #expect(phase.intent(for: .pasteLast) == expected)
  }

  @Test func pushToTalkPressWhileRecordingIsIgnored() {
    #expect(DictationPhase.recording(.toggle).intent(for: .pushToTalkStart) == .ignore)
  }
}
