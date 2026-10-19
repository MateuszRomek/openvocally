import Testing

@testable import DictationCore

struct DictationPhaseTests {
  @Test func `starting already shows recording`() {
    #expect(DictationPhase.starting(.pushToTalk).showsRecording)
    #expect(DictationPhase.recording(.toggle).showsRecording)
    #expect(!DictationPhase.transcribing.showsRecording)
    #expect(!DictationPhase.idle.showsRecording)
  }
}
