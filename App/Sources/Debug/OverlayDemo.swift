#if DEBUG
  import DictationCore
  import Foundation
  import Overlay
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "overlay-demo")

  /// Launch with `-overlayDemo YES` to drive the real overlay through a scripted loop instead of
  /// the hotkeys, `-overlayStyle notch` or `island` to pick its style, and `-overlayPlacement
  /// islandTop` or `islandBottom` to pick the island's edge.
  /// The pipeline never starts, so nothing is recorded or pasted.
  @MainActor enum OverlayDemo {
    static var isRequested: Bool {
      UserDefaults.standard.bool(forKey: "overlayDemo")
    }

    static func run(_ overlay: OverlayHost) async {
      while !Task.isCancelled {
        await step("starting", .starting(.pushToTalk), for: .milliseconds(400), overlay)
        overlay.show(OverlayActivity(dictation: .recording(.pushToTalk)), from: .dictation)
        logger.info("recording with meter")
        await feedMeter(overlay, for: .milliseconds(2500))
        await step("transcribing", .transcribing, for: .milliseconds(700), overlay)
        await step("pasting", .pasting, for: .milliseconds(200), overlay)
        await step("complete", .complete, for: .milliseconds(650), overlay)
        await step("hidden", .idle, for: .seconds(1), overlay)

        logger.info("connecting bluetooth mic")
        overlay.show(
          OverlayActivity(dictation: .starting(.pushToTalk), wakingMicrophone: true), from: .dictation)
        try? await Task.sleep(for: .milliseconds(1800))
        overlay.show(OverlayActivity(dictation: .recording(.pushToTalk)), from: .dictation)
        await feedMeter(overlay, for: .milliseconds(1500))
        await step("hidden", .idle, for: .seconds(1), overlay)

        await step("recording", .recording(.toggle), for: .seconds(1), overlay)
        await step("no speech", .failed(.noSpeech), for: .milliseconds(2900), overlay)
        await step("hidden", .idle, for: .seconds(1), overlay)

        await step("recording", .recording(.toggle), for: .seconds(1), overlay)
        await step("transcribing", .transcribing, for: .milliseconds(500), overlay)
        let until = HostTime.now().advanced(by: DictationMachine.manualPasteWindow)
        await step("manual paste", .awaitingManualPaste(until: until), for: .seconds(4), overlay)
        await step("manual paste expired", .failed(.manualPasteExpired), for: .milliseconds(2900), overlay)
        await step("hidden", .idle, for: .seconds(1), overlay)
      }
    }

    private static func step(
      _ name: String, _ phase: DictationPhase, for duration: Duration, _ overlay: OverlayHost
    ) async {
      logger.info("\(name, privacy: .public)")
      overlay.show(OverlayActivity(dictation: phase), from: .dictation)
      try? await Task.sleep(for: duration)
    }

    private static func feedMeter(_ overlay: OverlayHost, for duration: Duration) async {
      let start = ContinuousClock.now
      while ContinuousClock.now - start < duration, !Task.isCancelled {
        let t = (ContinuousClock.now - start) / .seconds(1)
        let loudness = 0.5 + 0.4 * sin(t * 5)
        overlay.meter(
          (0..<20).map { band in
            let centre = 1 - abs(Double(band) - 9.5) / 10
            return Float(max(0, min(1, loudness * centre + 0.15 * sin(t * 17 + Double(band)))))
          })
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }
#endif
