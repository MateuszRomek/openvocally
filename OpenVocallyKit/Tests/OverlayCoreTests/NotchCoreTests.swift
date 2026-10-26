import DictationCore
import OverlayCore
import Testing

private let one = DisplayID(rawValue: 1)
private let two = DisplayID(rawValue: 2)
private let manualPasteEnd = HostTime(ticks: 9_000_000_000)

private func strip(_ cue: MotionCue, _ lead: StripLead, on display: UInt32 = 1) -> RecordedFrame {
  RecordedFrame(display: display, footprint: .strip, cue: cue, strip: lead)
}

private func notice(_ cue: MotionCue, _ notice: Notice) -> RecordedFrame {
  RecordedFrame(display: 1, footprint: .noticeStrip, cue: cue, strip: .notice(notice))
}

private func hidden(_ cue: MotionCue, on display: UInt32 = 1) -> RecordedFrame {
  RecordedFrame(display: display, footprint: .hidden, cue: cue, strip: nil)
}

struct Row: CustomTestStringConvertible, Sendable {
  let name: String
  let events: [(NotchEvent, Duration)]
  let expected: [RecordedFrame]

  var testDescription: String { name }
}

private let press: NotchEvent = .dictation(.starting(.pushToTalk))
private let recording: NotchEvent = .dictation(.recording(.pushToTalk))
private let onOne: NotchEvent = .pointer(movedOnto: one)

private let failureReasons: [DictationFailureReason] = [
  .microphonePermissionDenied,
  .captureError(.noInputDevice), .captureError(.startTimedOut), .captureError(.stopTimedOut),
  .captureError(.deviceLost), .captureError(.captureFailed),
  .transcriptionError, .noSpeech, .modelNotInstalled, .pasteNotSupported,
  .pastePermissionDenied, .pasteRuntimeError, .nothingToPaste, .manualPasteExpired,
]

private let failureRows: [Row] = failureReasons.map { reason in
  Row(
    name: "failure \(reason)",
    events: [
      (onOne, .zero), (recording, .zero), (.dictation(.failed(reason)), .milliseconds(100)),
      (.dictation(.idle), .seconds(2)),
    ],
    expected: [
      strip(.keyboard, .voice(.recording)), notice(.grow, .failure(reason)), hidden(.shrink),
    ])
}

private let rows: [Row] =
  [
    Row(
      name: "dictation only",
      events: [
        (onOne, .zero), (press, .zero), (recording, .milliseconds(50)),
        (.dictation(.stopping), .seconds(1)), (.dictation(.transcribing), .milliseconds(10)),
        (.dictation(.pasting), .milliseconds(100)), (.dictation(.complete), .milliseconds(20)),
        (.dictation(.idle), .seconds(1)),
      ],
      expected: [
        strip(.keyboard, .voice(.starting)), strip(.content, .voice(.recording)),
        strip(.content, .voice(.transcribing)), strip(.content, .voice(.pasting)),
        strip(.content, .flash(.pasted)), hidden(.shrink),
      ]),
    Row(
      name: "slow mic",
      events: [(onOne, .zero), (press, .zero), (recording, .milliseconds(450))],
      expected: [
        strip(.keyboard, .voice(.starting)), strip(.content, .voice(.connecting)),
        strip(.content, .voice(.recording)),
      ]),
    Row(
      name: "fast mic",
      events: [(onOne, .zero), (press, .zero), (recording, .milliseconds(120))],
      expected: [strip(.keyboard, .voice(.starting)), strip(.content, .voice(.recording))]),
    Row(
      name: "a repeated start keeps the original deadline",
      events: [(onOne, .zero), (press, .zero), (press, .milliseconds(200)), (.tick, .milliseconds(100))],
      expected: [strip(.keyboard, .voice(.starting)), strip(.content, .voice(.connecting))]),
    Row(
      name: "cancel",
      events: [(onOne, .zero), (recording, .zero), (.dictation(.failed(.aborted)), .seconds(1))],
      expected: [strip(.keyboard, .voice(.recording)), hidden(.keyboard)]),
    Row(
      name: "manual paste",
      events: [
        (onOne, .zero), (.dictation(.transcribing), .zero),
        (.dictation(.awaitingManualPaste(until: manualPasteEnd)), .milliseconds(100)),
        (.dictation(.complete), .seconds(1)), (.dictation(.idle), .seconds(1)),
      ],
      expected: [
        strip(.grow, .voice(.transcribing)), notice(.grow, .manualPaste(until: manualPasteEnd)),
        strip(.shrink, .flash(.pasted)), hidden(.shrink),
      ]),
    Row(
      name: "press during a notice",
      events: [
        (onOne, .zero), (.dictation(.failed(.noSpeech)), .zero), (press, .seconds(1)),
      ],
      expected: [notice(.grow, .failure(.noSpeech)), strip(.keyboard, .voice(.starting))]),
    Row(
      name: "display hand-off",
      events: [(onOne, .zero), (recording, .zero), (.pointer(movedOnto: two), .seconds(1))],
      expected: [
        strip(.keyboard, .voice(.recording)), hidden(.shrink, on: 1),
        strip(.grow, .voice(.recording), on: 2),
      ]),
    Row(
      name: "pointer moves while hidden",
      events: [(onOne, .zero), (.pointer(movedOnto: two), .seconds(1)), (onOne, .seconds(1))],
      expected: []),
    Row(
      name: "ticks with nothing due change nothing",
      events: [(onOne, .zero), (recording, .zero), (.tick, .seconds(1)), (.tick, .zero)],
      expected: [strip(.keyboard, .voice(.recording))]),
  ] + failureRows

struct NotchCoreTests {
  @Test(arguments: rows)
  func `events produce exactly the expected frames`(row: Row) {
    var rig = NotchRig()
    for (event, delay) in row.events {
      rig.send(event, after: delay)
    }
    #expect(rig.frames == row.expected)
  }

  @Test func `nothing shows before the pointer reports a display`() {
    var core = NotchCore()
    let outcome = core.send(.dictation(.recording(.toggle)), at: HostTime(ticks: 1))
    #expect(outcome.frames.isEmpty)
    #expect(core.scene.strip == .voice(.recording))
  }
}
