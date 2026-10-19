import Testing
import Transcription

struct WordErrorRateTests {
  @Test func wordsDropCaseAndPunctuation() {
    #expect(
      WordErrorRate.words("Please move it, to Thursday!  I'm here.") == [
        "please", "move", "it", "to", "thursday", "im", "here",
      ])
    #expect(
      WordErrorRate.words("Przypomnij mi o dziesiątej — dobrze?") == [
        "przypomnij", "mi", "o", "dziesiątej", "dobrze",
      ])
  }

  @Test func identicalTextScoresZero() {
    #expect(WordErrorRate.rate(reference: "Send the agenda.", hypothesis: "send the agenda") == 0)
  }

  @Test func countsSubstitutionsInsertionsAndDeletions() {
    #expect(WordErrorRate.rate(reference: "a b c d", hypothesis: "a x c d") == 0.25)
    #expect(WordErrorRate.rate(reference: "a b c d", hypothesis: "a b c d e") == 0.25)
    #expect(WordErrorRate.rate(reference: "a b c d", hypothesis: "a c d") == 0.25)
    #expect(WordErrorRate.rate(reference: "a b c d", hypothesis: "") == 1)
  }

  @Test func emptyReference() {
    #expect(WordErrorRate.rate(reference: "", hypothesis: "") == 0)
    #expect(WordErrorRate.rate(reference: "", hypothesis: "words") == 1)
  }
}
