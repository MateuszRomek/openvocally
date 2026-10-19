import Testing

@testable import Transcription

struct RepeatedPhraseTests {
  @Test func `a phrase said twice in a row is a run of its words`() {
    #expect(RepeatedPhrase.longestRun(in: "Maybe around 2? Maybe around 2?") == 3)
  }

  @Test func `a repeat shorter than 3 words is not a run`() {
    #expect(RepeatedPhrase.longestRun(in: "bye bye") == 0)
    #expect(RepeatedPhrase.longestRun(in: "Thank you, thank you.") == 0)
  }

  @Test func `punctuation and case are ignored`() {
    #expect(RepeatedPhrase.longestRun(in: "See you at noon. see YOU, at noon!") == 4)
  }

  @Test func `a repeat in the middle of a sentence counts`() {
    #expect(
      RepeatedPhrase.longestRun(in: "So we ship it on Friday ship it on Friday and rest") == 4)
  }

  @Test func `text without a repeat has no run`() {
    #expect(RepeatedPhrase.longestRun(in: "The quick brown fox jumps over the lazy dog") == 0)
  }
}
