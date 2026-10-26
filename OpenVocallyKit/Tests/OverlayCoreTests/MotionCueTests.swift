import OverlayCore
import Testing

struct CueRow: Sendable, CustomTestStringConvertible {
  let from: Footprint
  let to: Footprint
  let cause: Cause
  let cue: MotionCue

  init(_ from: Footprint, _ to: Footprint, _ cause: Cause, _ cue: MotionCue) {
    self.from = from
    self.to = to
    self.cause = cause
    self.cue = cue
  }

  var testDescription: String { "\(from) -> \(to) by \(cause)" }
}

private let table: [CueRow] = [
  CueRow(.hidden, .hidden, .key, .content),
  CueRow(.hidden, .hidden, .pointer, .content),
  CueRow(.hidden, .hidden, .arrival, .content),
  CueRow(.hidden, .hidden, .timer, .content),
  CueRow(.hidden, .strip, .key, .keyboard),
  CueRow(.hidden, .strip, .pointer, .grow),
  CueRow(.hidden, .strip, .arrival, .grow),
  CueRow(.hidden, .strip, .timer, .grow),
  CueRow(.hidden, .noticeStrip, .key, .keyboard),
  CueRow(.hidden, .noticeStrip, .pointer, .grow),
  CueRow(.hidden, .noticeStrip, .arrival, .grow),
  CueRow(.hidden, .noticeStrip, .timer, .grow),
  CueRow(.strip, .hidden, .key, .keyboard),
  CueRow(.strip, .hidden, .pointer, .shrink),
  CueRow(.strip, .hidden, .arrival, .shrink),
  CueRow(.strip, .hidden, .timer, .shrink),
  CueRow(.strip, .strip, .key, .content),
  CueRow(.strip, .strip, .pointer, .content),
  CueRow(.strip, .strip, .arrival, .content),
  CueRow(.strip, .strip, .timer, .content),
  CueRow(.strip, .noticeStrip, .key, .keyboard),
  CueRow(.strip, .noticeStrip, .pointer, .grow),
  CueRow(.strip, .noticeStrip, .arrival, .grow),
  CueRow(.strip, .noticeStrip, .timer, .grow),
  CueRow(.noticeStrip, .hidden, .key, .keyboard),
  CueRow(.noticeStrip, .hidden, .pointer, .shrink),
  CueRow(.noticeStrip, .hidden, .arrival, .shrink),
  CueRow(.noticeStrip, .hidden, .timer, .shrink),
  CueRow(.noticeStrip, .strip, .key, .keyboard),
  CueRow(.noticeStrip, .strip, .pointer, .shrink),
  CueRow(.noticeStrip, .strip, .arrival, .shrink),
  CueRow(.noticeStrip, .strip, .timer, .shrink),
  CueRow(.noticeStrip, .noticeStrip, .key, .content),
  CueRow(.noticeStrip, .noticeStrip, .pointer, .content),
  CueRow(.noticeStrip, .noticeStrip, .arrival, .content),
  CueRow(.noticeStrip, .noticeStrip, .timer, .content),
]

struct MotionCueTests {
  @Test func `the table covers every footprint pair and cause`() {
    #expect(table.count == Footprint.allCases.count * Footprint.allCases.count * Cause.allCases.count)
  }

  @Test(arguments: table)
  func `choose picks the pinned cue`(row: CueRow) {
    #expect(MotionCue.choose(from: row.from, to: row.to, cause: row.cause) == row.cue)
  }
}
