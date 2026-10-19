import Synchronization
import Testing

@testable import Transcription

let second = 16_000

func speech(_ seconds: Double) -> [Float] {
  [Float](repeating: 0.1, count: Int(seconds * Double(second)))
}

func quiet(_ seconds: Double) -> [Float] {
  [Float](repeating: 0, count: Int(seconds * Double(second)))
}

struct TrailingQuietTests {
  @Test func `quiet past 300 ms after the last word is dropped`() {
    #expect(TrailingQuiet.trimmed(speech(2) + quiet(1)).count == 36_800)
  }

  @Test func `a recording without speech or ending in speech is kept whole`() {
    #expect(TrailingQuiet.trimmed(quiet(2)).count == 32_000)
    #expect(TrailingQuiet.trimmed(quiet(1) + speech(2)).count == 48_000)
  }

  @Test func `a pause trims to what the release will unless the user speaks again`() {
    let paused = speech(2) + quiet(0.5)
    #expect(TrailingQuiet.trimmed(paused) == TrailingQuiet.trimmed(paused + quiet(0.7)))
    #expect(TrailingQuiet.trimmed(paused) != TrailingQuiet.trimmed(paused + speech(0.5)))
  }
}
