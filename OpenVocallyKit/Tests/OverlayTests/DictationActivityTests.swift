import DictationCore
import Foundation
import Testing

@testable import Overlay

struct DictationActivityTests {
  static let until = HostTime(ticks: 1)

  static let phases: [DictationPhase] = [
    .starting(.pushToTalk), .recording(.toggle), .stopping, .transcribing, .pasting, .complete,
    .awaitingManualPaste(until: until), .failed(.manualPasteExpired), .failed(.nothingToPaste),
    .failed(.microphonePermissionDenied), .failed(.captureError(.noInputDevice)),
    .failed(.transcriptionError), .failed(.pasteRuntimeError),
  ]

  @Test(arguments: [
    (
      DictationPhase.starting(.pushToTalk), OverlayGlyph?.none,
      OverlayActivity.Body.compact(.bars(.pulse)), "Recording"
    ),
    (.recording(.toggle), nil, .compact(.bars(.live)), "Recording"),
    (.stopping, nil, .compact(.bars(.sweep)), "Transcribing"),
    (.transcribing, nil, .compact(.bars(.sweep)), "Transcribing"),
    (.pasting, nil, .compact(.bars(.sweep)), "Pasting"),
    (.complete, .success, .compact(.status), "Pasted"),
  ])
  func `frequent phases stay compact`(
    phase: DictationPhase, glyph: OverlayGlyph?, body: OverlayActivity.Body, status: String
  ) throws {
    let activity = try #require(OverlayActivity(dictation: phase))
    #expect(activity.level == .compact)
    #expect(activity.glyph == glyph)
    #expect(activity.body == body)
    #expect(activity.status.text == status)
  }

  @Test func `a waking mic names the start and nothing else`() throws {
    let starting = try #require(OverlayActivity(dictation: .starting(.pushToTalk), wakingMicrophone: true))
    #expect(starting.status.text == "Connecting")
    #expect(starting.body == .compact(.status))
    let recording = try #require(OverlayActivity(dictation: .recording(.pushToTalk), wakingMicrophone: true))
    #expect(recording.status.text == "Recording")
  }

  @Test(arguments: [
    (DictationPhase.awaitingManualPaste(until: until), OverlayGlyph?.none, "Ready to paste"),
    (.failed(.manualPasteExpired), nil, "Not pasted"),
    (.failed(.nothingToPaste), .attention, "Nothing to paste"),
    (.failed(.microphonePermissionDenied), .attention, "Failed"),
    (.failed(.captureError(.deviceLost)), .attention, "Failed"),
    (.failed(.noSpeech), .attention, "Failed"),
    (.failed(.pasteNotSupported), .attention, "Failed"),
  ])
  func `rare phases grow to an alert`(phase: DictationPhase, glyph: OverlayGlyph?, status: String)
    throws
  {
    let activity = try #require(OverlayActivity(dictation: phase))
    #expect(activity.level == .alert)
    #expect(activity.glyph == glyph)
    #expect(activity.status.text == status)
  }

  @Test(arguments: [DictationPhase.idle, .failed(.aborted)])
  func `idle and cancel show nothing`(phase: DictationPhase) {
    #expect(OverlayActivity(dictation: phase) == nil)
  }

  @Test func `a cancel has no copy`() {
    #expect(OverlayActivity.message(for: .aborted)?.description == nil)
  }

  @Test(arguments: [
    (DictationFailureReason.microphonePermissionDenied, "Microphone access needed"),
    (.captureError(.noInputDevice), "No microphone found"),
    (.captureError(.startTimedOut), "Microphone didn't start"),
    (.captureError(.stopTimedOut), "Recording didn't stop"),
    (.captureError(.deviceLost), "Microphone disconnected"),
    (.captureError(.captureFailed), "Couldn't record"),
    (.transcriptionError, "Couldn't transcribe"),
    (.noSpeech, "No speech detected"),
    (.modelNotInstalled, "Download a model in Models"),
    (.pasteNotSupported, "Can't paste here"),
    (.pastePermissionDenied, "Accessibility access needed"),
    (.pasteRuntimeError, "Couldn't paste"),
    (.nothingToPaste, "Nothing to paste yet"),
    (.manualPasteExpired, "Saved to Transcripts"),
  ])
  func `each failure has its copy`(reason: DictationFailureReason, copy: String) {
    #expect(OverlayActivity.message(for: reason)?.description == copy)
    #expect(OverlayActivity(dictation: .failed(reason))?.level == .alert)
  }

  @Test func `manual paste asks for command V with a countdown`() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    let activity = try #require(
      OverlayActivity(
        dictation: .awaitingManualPaste(until: Self.until.advanced(by: .seconds(4))), now: now,
        hostNow: Self.until))
    guard case .alert(let alert) = activity.body else {
      Issue.record("expected an alert")
      return
    }
    #expect(alert.message == "Copied. Paste with")
    #expect(alert.keys == ["⌘V"])
    #expect(abs((alert.countdown?.ends ?? now).timeIntervalSince(now) - 4) < 0.001)
    #expect(alert.countdown?.total == .seconds(10))
    #expect(alert.accessibilityLabel == "Copied. Paste with ⌘V")
  }

  @Test(arguments: phases)
  func `compact status words are at most two words`(phase: DictationPhase) throws {
    let activity = try #require(OverlayActivity(dictation: phase))
    guard activity.level == .compact else { return }
    #expect(activity.status.text.split(separator: " ").count <= 2)
  }
}

struct OverlayAlertTests {
  @Test func `key caps are spoken after the message`() {
    #expect(OverlayAlert("Couldn't paste").accessibilityLabel == "Couldn't paste")
    #expect(
      OverlayAlert("Copied. Paste with", keys: ["⌘V"]).accessibilityLabel == "Copied. Paste with ⌘V")
  }
}

struct CountdownTests {
  @Test func `the countdown ends when the manual paste window closes`() {
    let hostNow = HostTime.now()
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    let open = OverlayActivity.wallClock(hostNow.advanced(by: .seconds(4)), now: now, hostNow: hostNow)
    #expect(abs(open.timeIntervalSince(now) - 4) < 0.001)
    let late = OverlayActivity.wallClock(hostNow, now: now, hostNow: hostNow.advanced(by: .seconds(1)))
    #expect(late == now)
  }
}
