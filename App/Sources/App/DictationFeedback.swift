import Dictation
import DictationCore
import Foundation
import Observation
import Overlay

/// What the user sees of a dictation outside the window: the overlay, the phase the menus title
/// themselves by, the LB-01 feedback mark and the onboarding's overlay preview. Every rule
/// about when the overlay shows lives here.
@MainActor @Observable final class DictationFeedback {
  private(set) var phase = DictationPhase.idle

  @ObservationIgnored private var overlay: OverlayHost?
  @ObservationIgnored private var preview: Task<Void, Never>?
  @ObservationIgnored private var connecting: Task<Void, Never>?
  @ObservationIgnored private var shownSession: SessionID?

  private static let previewLength: Duration = .milliseconds(1600)
  private static let previewMeterTick: Duration = .milliseconds(50)

  /// Launch. The overlay is made here rather than at init, because the model is built before the
  /// app finishes launching.
  func prepare() {
    #if DEBUG
      let overlay = OverlayProbe.isRequested ? OverlayHost(pointer: { OverlayProbe.pointer }) : OverlayHost()
    #else
      let overlay = OverlayHost()
    #endif
    overlay.prewarm()
    self.overlay = overlay
  }

  func meter(_ bands: [Float]) {
    overlay?.meter(bands)
  }

  /// One pipeline update that the Try it card did not take.
  func show(_ update: DictationUpdate) {
    connecting?.cancel()
    // A one-key hold shows nothing until confirmed, so a ⌘ shortcut never flashes,
    // not even in the menu titles.
    if update.hold?.isConfirmed == false { return }
    if update.phase != .idle { cancelPreview() }
    phase = update.phase
    overlay?.show(OverlayActivity(dictation: update.phase), from: .dictation)
    if case .starting = update.phase {
      connecting = Task { [overlay] in
        try? await Task.sleep(for: OverlayActivity.connectingDelay)
        guard !Task.isCancelled else { return }
        overlay?.show(OverlayActivity(dictation: update.phase, wakingMicrophone: true), from: .dictation)
      }
    }
    if let pressedAt = update.pressedAt, update.session != shownSession, update.phase.showsRecording {
      shownSession = update.session
      Latency.feedbackShown(pressedAt: pressedAt, trigger: update.hold == nil ? .press : .hold)
    }
  }

  /// The update stream ended.
  func finish() {
    connecting?.cancel()
  }

  /// The real overlay at its true place for a moment, in the style just picked. Never during a
  /// dictation, and a new preview replaces the one showing.
  func previewOverlay() {
    guard let overlay, phase == .idle else { return }
    let restarting = preview != nil
    preview?.cancel()
    preview = Task { [overlay] in
      // Hidden first, so the host places the panel again with the newly stored style.
      if restarting { overlay.show(OverlayActivity(dictation: .idle), from: .dictation) }
      overlay.show(OverlayActivity(dictation: .recording(.pushToTalk)), from: .dictation)
      let start = ContinuousClock.now
      while ContinuousClock.now - start < Self.previewLength, !Task.isCancelled {
        overlay.meter(Self.previewBands(at: (ContinuousClock.now - start) / .seconds(1)))
        try? await Task.sleep(for: Self.previewMeterTick)
      }
      guard !Task.isCancelled else { return }
      overlay.show(OverlayActivity(dictation: .idle), from: .dictation)
      preview = nil
    }
  }

  private func cancelPreview() {
    preview?.cancel()
    preview = nil
  }

  /// Synthetic meter bands for the preview: a voice-like swell, loudest in the middle bands.
  private static func previewBands(at t: Double) -> [Float] {
    let loudness = 0.5 + 0.4 * sin(t * 5)
    return (0..<20).map { band in
      let centre = 1 - abs(Double(band) - 9.5) / 10
      return Float(max(0, min(1, loudness * centre + 0.15 * sin(t * 17 + Double(band)))))
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
