import Testing
import Transcription

@testable import model_bench

private typealias Counts = CountingTranscriber.Counts

@Test func settlesOnTwoIdleListensWithNoCallBetween() {
  var detector = SettleDetector()
  let now = ContinuousClock.now
  detector.listened(Counts(transcribes: 1), at: now)
  #expect(!detector.isSettled)
  detector.listened(Counts(transcribes: 2), at: now)
  #expect(!detector.isSettled)
  detector.listened(Counts(transcribes: 2), at: now)
  #expect(detector.isSettled)
}

@Test func aCallInFlightBreaksTheRun() {
  var detector = SettleDetector()
  let now = ContinuousClock.now
  detector.listened(Counts(transcribes: 1), at: now)
  detector.listened(Counts(transcribes: 1, pinging: 1), at: now)
  detector.listened(Counts(transcribes: 1), at: now)
  #expect(!detector.isSettled)
  detector.listened(Counts(transcribes: 1), at: now)
  #expect(detector.isSettled)
}

@Test func settlesAfterQuietWhenTheRuntimeStoppedListening() {
  var detector = SettleDetector()
  let start = ContinuousClock.now
  detector.poll(Counts(transcribes: 1), at: start)
  detector.poll(Counts(transcribes: 1, pinging: 1), at: start + .seconds(1))
  #expect(!detector.isSettled)
  detector.poll(Counts(transcribes: 2), at: start + .seconds(1))
  detector.poll(Counts(transcribes: 2), at: start + .seconds(2))
  #expect(!detector.isSettled)
  detector.poll(Counts(transcribes: 2), at: start + .seconds(3))
  #expect(detector.isSettled)
}

/// Speech-like noise, then a pause long enough for the runtime to call the recording settled.
private func recording(speech seconds: Double, quiet: Double) -> [Float] {
  var generator = SystemRandomNumberGenerator()
  let speech = (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
  return speech + repeatElement(0, count: Int(quiet * 16_000))
}

@Test func planDecodesASettledShortRecordingWhileRecording() async throws {
  let inputs = try await planInputs(recording(speech: 3, quiet: 1), lookahead: WhisperTranscriber.lookahead)
  #expect(inputs.early.count == 1)
  #expect(inputs.early.first?.lowerBound == 0)
  #expect(inputs.release.isEmpty)
  #expect(planLine("x", inputs, width: 1).hasPrefix("x  early: 0.00-"))
  #expect(planLine("x", inputs, width: 1).hasSuffix("release: -"))
}

@Test func planLeavesAnUnsettledRecordingToTheRelease() async throws {
  let inputs = try await planInputs(recording(speech: 3, quiet: 0), lookahead: WhisperTranscriber.lookahead)
  #expect(inputs == PlannedInputs(early: [], release: [0..<48_000]))
}
