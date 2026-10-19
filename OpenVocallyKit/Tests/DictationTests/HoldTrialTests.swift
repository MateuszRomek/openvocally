import DictationCore
import Testing

@testable import Dictation

/// The push-to-talk Try it card: which updates it takes from the overlay and what it shows.
struct HoldTrialTests {
  private static let trialHold = Hold(isConfirmed: true, isTrial: true)

  private func update(
    _ phase: DictationPhase, hold: Hold? = nil, result: TrialResult? = nil
  ) -> DictationUpdate {
    DictationUpdate(phase: phase, session: nil, pressedAt: nil, hold: hold, trialResult: result)
  }

  @Test func `a trial update is claimed with no card on screen`() {
    #expect(HoldTrial.claims(update(.recording(.pushToTalk), hold: Self.trialHold), trialActive: false))
    let failed = update(.idle, result: .failed(.noSpeech))
    #expect(HoldTrial.claims(failed, trialActive: false))
  }

  @Test func `idle is claimed only while a card is on screen`() {
    #expect(HoldTrial.claims(update(.idle), trialActive: true))
    #expect(!HoldTrial.claims(update(.idle), trialActive: false))
  }

  @Test func `an ordinary dictation is left to the overlay during a trial`() {
    let confirmed = Hold(isConfirmed: true, isTrial: false)
    #expect(!HoldTrial.claims(update(.recording(.pushToTalk), hold: confirmed), trialActive: true))
    #expect(!HoldTrial.claims(update(.recording(.toggle)), trialActive: true))
  }

  @Test func `an aborted trial goes back to waiting`() {
    let aborted = update(.idle, result: .failed(.aborted))
    #expect(HoldTrial.listening(level: 0.4).applying(aborted) == .waiting)
  }

  @Test func `any other failure shows its reason`() {
    let silent = update(.idle, result: .failed(.noSpeech))
    #expect(HoldTrial.listening(level: 0.4).applying(silent) == .failed(.noSpeech))
    let noModel = update(.idle, result: .failed(.modelNotInstalled))
    #expect(HoldTrial.waiting.applying(noModel) == .failed(.modelNotInstalled))
  }

  @Test func `a heard transcript shows its text`() throws {
    let transcript = try #require(Transcript("  hello there "))
    let heard = update(.idle, result: .heard(transcript))
    #expect(HoldTrial.listening(level: 0.4).applying(heard) == .heard("hello there"))
  }

  @Test func `recording starts listening at zero and keeps the metered level`() {
    let recording = update(.recording(.pushToTalk), hold: Self.trialHold)
    #expect(HoldTrial.waiting.applying(recording) == .listening(level: 0))
    #expect(HoldTrial.listening(level: 0.7).applying(recording) == .listening(level: 0.7))
    let starting = update(.starting(.pushToTalk), hold: Self.trialHold)
    #expect(HoldTrial.listening(level: 0.7).applying(starting) == .listening(level: 0.7))
  }

  @Test func `idle after listening goes back to waiting`() {
    #expect(HoldTrial.listening(level: 0.7).applying(update(.idle)) == .waiting)
    #expect(HoldTrial.heard("hello").applying(update(.idle)) == .heard("hello"))
    #expect(HoldTrial.failed(.noSpeech).applying(update(.idle)) == .failed(.noSpeech))
  }

  @Test func `a phase between recording and idle changes nothing`() {
    let transcribing = update(.transcribing, hold: Self.trialHold)
    #expect(HoldTrial.listening(level: 0.7).applying(transcribing) == .listening(level: 0.7))
    #expect(HoldTrial.waiting.applying(transcribing) == .waiting)
  }

  @Test func `only a listening card takes a level`() {
    #expect(HoldTrial.listening(level: 0).heard(level: 0.5) == .listening(level: 0.5))
    #expect(HoldTrial.waiting.heard(level: 0.5) == nil)
    #expect(HoldTrial.heard("hello").heard(level: 0.5) == nil)
  }
}
