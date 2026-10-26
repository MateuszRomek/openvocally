import AppKit
import DictationCore
import Foundation
import OverlayCore

/// One `NotchFrame` with the activity it draws, resolved once when the frame arrives so the
/// manual paste deadline converts to one wall-clock time.
struct NotchDrawing: Equatable {
  let scene: NotchScene
  let motion: MotionCue
  let activity: OverlayActivity?

  init(_ frame: NotchFrame, now: Date = .now, hostNow: HostTime = .now()) {
    self.init(scene: frame.scene, motion: frame.motion, now: now, hostNow: hostNow)
  }

  private init(scene: NotchScene, motion: MotionCue, now: Date = .now, hostNow: HostTime = .now()) {
    self.scene = scene
    self.motion = motion
    activity = scene.strip.flatMap { OverlayActivity(lead: $0, now: now, hostNow: hostNow) }
  }

  static let hidden = NotchDrawing(scene: .hidden, motion: .content)

  /// The frame a fresh notch shows after `phases`, from a scratch `NotchCore`, so previews and
  /// prewarming build frames the way the host does. `waitingForMicrophone` lets the
  /// connecting deadline pass after the last phase.
  static func after(_ phases: [DictationPhase], waitingForMicrophone: Bool = false) -> NotchDrawing {
    var core = NotchCore()
    var now = HostTime.now()
    var last: NotchFrame?
    let display = DisplayID(rawValue: 0)
    _ = core.send(.pointer(movedOnto: display), at: now)
    for phase in phases {
      last = core.send(.dictation(phase), at: now).frames[display] ?? last
    }
    if waitingForMicrophone, let deadline = core.nextDeadline {
      now = deadline
      last = core.send(.tick, at: now).frames[display] ?? last
    }
    return last.map { NotchDrawing($0) } ?? .hidden
  }
}

extension OverlayActivity {
  /// The notch draws each lead as the activity the pill drew for the same phase, so both share
  /// one copy table and one look. The recording mode changes nothing that is drawn.
  init?(lead: StripLead, now: Date = .now, hostNow: HostTime = .now()) {
    switch lead {
    case .voice(.starting): self.init(dictation: .starting(.pushToTalk))
    case .voice(.connecting): self.init(dictation: .starting(.pushToTalk), wakingMicrophone: true)
    case .voice(.recording): self.init(dictation: .recording(.pushToTalk))
    case .voice(.transcribing): self.init(dictation: .transcribing)
    case .voice(.pasting): self.init(dictation: .pasting)
    case .flash(.pasted): self.init(dictation: .complete)
    case .notice(.manualPaste(let until)):
      self.init(dictation: .awaitingManualPaste(until: until), now: now, hostNow: hostNow)
    case .notice(.failure(let reason)): self.init(dictation: .failed(reason))
    }
  }
}

/// Where the dictation notch draws on one display: under the hardware notch, or at the
/// simulated notch's size on the top edge of a display without one.
struct NotchPlacement: Equatable, Sendable {
  let notch: NotchGeometry
  /// A real notch hides the hidden shape behind the camera; without one, hidden draws nothing.
  let hardware: Bool

  @MainActor init(_ screen: NSScreen) {
    if let notch = NotchGeometry(ScreenGeometry(screen)) {
      self.init(notch: notch, hardware: true)
    } else {
      self.init(
        notch: NotchGeometry(size: OverlayMetrics.notchSimulated, midX: screen.frame.midX), hardware: false)
    }
  }

  init(notch: NotchGeometry, hardware: Bool) {
    self.notch = notch
    self.hardware = hardware
  }

  /// The canvas pinned to the screen's top edge, centered on the notch.
  func panelFrame(on screen: CGRect) -> CGRect {
    let size = OverlayMetrics.canvas
    return CGRect(
      x: notch.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
  }

  /// The drawn shape for a footprint. Pure, so a content change within one footprint can never
  /// move the shape, and tests can read it without a window.
  func shapeSize(_ footprint: Footprint) -> CGSize {
    let width = notch.size.width + 2 * OverlayMetrics.notchStripWing
    switch footprint {
    case .hidden:
      return hardware ? notch.hiddenSize : CGSize(width: notch.hiddenSize.width, height: 0)
    case .strip:
      return CGSize(width: width, height: notch.size.height)
    case .noticeStrip:
      return CGSize(width: width, height: notch.size.height + OverlayMetrics.notchNoticeDrop)
    }
  }

  static func radii(_ footprint: Footprint) -> NotchRadii {
    switch footprint {
    case .hidden: OverlayMetrics.notchHiddenRadii
    case .strip: OverlayMetrics.notchCompactRadii
    case .noticeStrip: OverlayMetrics.notchAlertRadii
    }
  }
}
