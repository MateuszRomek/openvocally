import Testing

@testable import Transcription

private func sound(_ level: Float, _ seconds: Double) -> [Float] {
  [Float](repeating: level, count: Int(seconds * Double(second)))
}

private let pieces = Lookahead.pieces(shortest: 2 * second, longest: 4 * second)

struct ReleasePlanTests {
  @Test func `pieces are the same however the recording is fed`() {
    let recording = speech(2.5) + quiet(0.5) + speech(5) + quiet(0.5) + speech(1)
    var whole = ReleasePlanner(pieces)
    let expected = whole.plan(recording)
    #expect(expected.pieces.count == 3)

    for step in [1001, 1600, 320] {
      var planner = ReleasePlanner(pieces)
      var plan = planner.plan([])
      for end in stride(from: step, to: recording.count + step, by: step) {
        plan = planner.plan(Array(recording[..<min(end, recording.count)]))
      }
      #expect(plan == expected, "fed in steps of \(step)")
    }
  }

  @Test func `a pause after the shortest piece cuts in the middle of the pause`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(speech(2.5) + quiet(0.5) + speech(1))
    #expect(plan.pieces == [0..<44_000])
    #expect(plan.tail == 44_000..<64_000)
    #expect(!plan.tailIsSettled)
  }

  @Test func `a pause before the shortest piece does not cut`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(speech(1) + quiet(0.5) + speech(1))
    #expect(plan.pieces.isEmpty)
    #expect(plan.tail == 0..<40_000)
  }

  @Test func `a piece that reaches the longest cuts at the quietest frame of the last 2 s`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(speech(3) + sound(0.05, 0.02) + speech(2))
    #expect(plan.pieces == [0..<48_320])
  }

  @Test func `a pause that starts before the shortest piece cuts once the piece reaches it`() {
    var planner = ReleasePlanner(pieces)
    #expect(planner.plan(speech(1.7) + quiet(1) + speech(1)).pieces == [0..<35_200])
  }

  @Test func `a loud click does not hide the speech after it`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(sound(1, 0.02) + speech(2.5) + quiet(0.5) + speech(1))
    #expect(plan.pieces == [0..<44_320])
    #expect(plan.tail != nil)
  }

  @Test func `quiet is relative to the recent peak`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(speech(2.5) + sound(0.005, 0.5) + speech(1))
    #expect(plan.pieces == [0..<44_000])
  }

  @Test func `a pause the recording ends in does not cut`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(speech(2.5) + sound(0.001, 1))
    #expect(plan.pieces.isEmpty)
    #expect(plan.tail == 0..<44_800)
    #expect(plan.tailIsSettled)
  }

  @Test func `a tail of silence after the last piece is dropped`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(speech(2.5) + quiet(0.5) + speech(1) + sound(0.001, 4.5))
    #expect(plan.inputs == [0..<44_000, 44_000..<76_480])
    #expect(plan.tail == nil)
  }

  @Test func `a piece with no speech is dropped`() {
    var planner = ReleasePlanner(pieces)
    let plan = planner.plan(sound(0.0001, 4.5) + speech(1))
    #expect(plan.pieces.isEmpty)
    #expect(plan.inputs.count == 1)
  }

  @Test func `a recording of silence has nothing to decode`() {
    var planner = ReleasePlanner(pieces)
    #expect(planner.plan(quiet(3)).inputs.isEmpty)
  }

  @Test func `the whole-recording plan is the trimmed recording, settled only after a pause`() {
    var planner = ReleasePlanner(.wholeRecording(window: 15 * second))
    #expect(planner.plan(speech(2)) == ReleasePlan(pieces: [], tail: 0..<32_000, tailIsSettled: false))
    #expect(
      planner.plan(speech(2) + quiet(0.5))
        == ReleasePlan(pieces: [], tail: 0..<36_800, tailIsSettled: true))
  }
}
