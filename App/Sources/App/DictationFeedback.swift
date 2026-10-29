import AppKit
import Dictation
import DictationCore
import Foundation
import Observation
import Overlay

/// What the user sees of a dictation outside the window: the notch, the phase the menus title
/// themselves by and the LB-01 feedback mark. Every rule about when the notch shows lives here.
@MainActor @Observable final class DictationFeedback {
  private(set) var phase = DictationPhase.idle

  @ObservationIgnored private var overlay: NotchHost?
  @ObservationIgnored private var shownSession: SessionID?

  /// Launch. The overlay is made here rather than at init, because the model is built before the
  /// app finishes launching.
  func prepare() {
    #if DEBUG
      // `-notchReduceMotion YES` or `NO` forces the notch's Reduce Motion variant.
      let defaults = UserDefaults.standard
      let reduceMotion =
        defaults.object(forKey: "notchReduceMotion") == nil ? nil : defaults.bool(forKey: "notchReduceMotion")
      let separateSpaces =
        defaults.object(forKey: "notchSeparateSpaces") == nil
        ? nil : defaults.bool(forKey: "notchSeparateSpaces")
      // `-notchAppearance aqua`, `darkAqua`, `highContrastAqua` or `highContrastDarkAqua` forces
      // the panels' appearance.
      let appearance: NSAppearance.Name? =
        switch defaults.string(forKey: "notchAppearance") {
        case "aqua": .aqua
        case "darkAqua": .darkAqua
        case "highContrastAqua": .accessibilityHighContrastAqua
        case "highContrastDarkAqua": .accessibilityHighContrastDarkAqua
        default: nil
        }
      let overlay =
        OverlayProbe.isRequested
        ? NotchHost(
          pointer: { OverlayProbe.pointer }, reduceMotion: reduceMotion, appearance: appearance,
          separateSpaces: separateSpaces)
        : NotchHost(reduceMotion: reduceMotion, appearance: appearance, separateSpaces: separateSpaces)
    #else
      let overlay = NotchHost()
    #endif
    overlay.prewarm()
    self.overlay = overlay
  }

  func meter(_ bands: [Float]) {
    overlay?.meter(bands)
  }

  /// One pipeline update that the Try it card did not take.
  func show(_ update: DictationUpdate) {
    // A one-key hold shows nothing until confirmed, so a ⌘ shortcut never flashes,
    // not even in the menu titles.
    if update.hold?.isConfirmed == false { return }
    phase = update.phase
    overlay?.show(update.phase)
    if let pressedAt = update.pressedAt, update.session != shownSession, update.phase.showsRecording {
      shownSession = update.session
      Latency.feedbackShown(pressedAt: pressedAt, trigger: update.hold == nil ? .press : .hold)
    }
  }

  #if DEBUG
    /// Drives the overlay through a scripted loop instead of the pipeline.
    func runDemo() async {
      guard let overlay else { return }
      await OverlayDemo.run(overlay)
    }

    func runProbe() async {
      guard let overlay else { return }
      await OverlayProbe.run(overlay)
    }
  #endif
}
