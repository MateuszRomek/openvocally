import AppKit
import DictationCore
import OverlayCore
import SwiftUI
import Testing

@testable import Overlay

@MainActor struct NotchFrameTests {
  nonisolated static let placements = [
    NotchPlacement(notch: .simulated, hardware: true), NotchPlacement(notch: .simulated, hardware: false),
  ]

  nonisolated static let samples: [Footprint: [DictationPhase]] = [
    .hidden: [],
    .strip: [.recording(.toggle)],
    .noticeStrip: [.recording(.toggle), .failed(.noSpeech)],
  ]

  static func drawn(_ phases: [DictationPhase], on placement: NotchPlacement) -> CGSize {
    let view = NotchFrameView(drawing: .after(phases), placement: placement).environment(BarsModel())
    return NSHostingView(rootView: view).fittingSize
  }

  @Test(arguments: placements)
  func `each footprint draws a strictly bigger shape than the last`(placement: NotchPlacement) throws {
    var areas: [CGFloat] = []
    for footprint in Footprint.allCases {
      let phases = try #require(Self.samples[footprint])
      #expect(NotchDrawing.after(phases).scene.footprint == footprint)
      let size = Self.drawn(phases, on: placement)
      #expect(size == placement.shapeSize(footprint))
      areas.append(size.width * size.height)
    }
    #expect(zip(areas, areas.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test func `hidden draws nothing without a hardware notch`() {
    #expect(Self.drawn([], on: NotchPlacement(notch: .simulated, hardware: false)).height == 0)
  }

  nonisolated static let reasons: [DictationFailureReason] = [
    .microphonePermissionDenied,
    .captureError(.noInputDevice), .captureError(.startTimedOut), .captureError(.stopTimedOut),
    .captureError(.deviceLost), .captureError(.captureFailed),
    .transcriptionError, .noSpeech, .modelNotInstalled, .pasteNotSupported,
    .pastePermissionDenied, .pasteRuntimeError, .nothingToPaste, .manualPasteExpired,
  ]

  nonisolated static let scenes: [[DictationPhase]] =
    [
      [.starting(.pushToTalk)], [.recording(.toggle)], [.transcribing], [.pasting], [.complete],
      [.awaitingManualPaste(until: HostTime.now().advanced(by: .seconds(10)))],
    ] + reasons.map { [.failed($0)] }

  /// The shape's size comes from the footprint alone, so its content must fit inside it.
  @Test(arguments: scenes)
  func `every scene's content fits its shape`(phases: [DictationPhase]) throws {
    let drawing = NotchDrawing.after(phases)
    let activity = try #require(drawing.activity)
    let placement = NotchPlacement(notch: .simulated, hardware: true)
    let shape = placement.shapeSize(drawing.scene.footprint)
    let content = NSHostingView(
      rootView: NotchFrameContent(activity: activity, notch: placement.notch).environment(BarsModel())
    ).fittingSize
    #expect(content.width <= shape.width)
    #expect(content.height <= shape.height)
    if case .alert(let alert) = activity.body {
      let line = NSHostingView(rootView: AlertBlock(alert: alert)).fittingSize
      #expect(line.height + 2 * OverlayMetrics.notchWingInset <= OverlayMetrics.notchNoticeDrop, "\(line)")
    }
  }

  @Test func `a voice and a flash share the strip footprint`() {
    #expect(NotchDrawing.after([.complete]).scene.footprint == .strip)
  }

  @Test func `connecting shows once the deadline passes`() {
    let drawing = NotchDrawing.after([.starting(.pushToTalk)], waitingForMicrophone: true)
    #expect(drawing.scene.strip == .voice(.connecting))
    #expect(drawing.activity?.accessibilityLabel == "Connecting")
  }

  @Test(arguments: reasons)
  func `the notch shows the failure's copy for every failure`(reason: DictationFailureReason) {
    let notch = OverlayActivity(lead: .notice(.failure(reason)))
    #expect(notch == OverlayActivity(dictation: .failed(reason)))
    #expect(notch?.accessibilityLabel == reason.overlayMessage?.description)
  }
}
