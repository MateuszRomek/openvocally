#if DEBUG
  import DictationCore
  import Foundation
  import Overlay
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "overlay-demo")

  #if FEATURE_NOTCH
    typealias DemoOverlay = NotchHost
  #else
    typealias DemoOverlay = OverlayHost
  #endif

  /// Launch with `-overlayDemo YES` to drive the real overlay through a scripted loop instead of
  /// the hotkeys, `-overlayStyle notch` or `island` to pick its style, and `-overlayPlacement
  /// islandTop` or `islandBottom` to pick the island's edge.
  /// The pipeline never starts, so nothing is recorded or pasted.
  @MainActor enum OverlayDemo {
    static var isRequested: Bool {
      UserDefaults.standard.bool(forKey: "overlayDemo")
    }

    static func run(_ overlay: DemoOverlay) async {
      while !Task.isCancelled {
        await step("starting", .starting(.pushToTalk), for: .milliseconds(400), overlay)
        show(.recording(.pushToTalk), on: overlay)
        logger.info("recording with meter")
        await feedMeter(overlay, for: .milliseconds(2500))
        await step("transcribing", .transcribing, for: .milliseconds(700), overlay)
        await step("pasting", .pasting, for: .milliseconds(200), overlay)
        await step("complete", .complete, for: .milliseconds(650), overlay)
        await step("hidden", .idle, for: .seconds(1), overlay)

        logger.info("connecting bluetooth mic")
        show(.starting(.pushToTalk), wakingMicrophone: true, on: overlay)
        try? await Task.sleep(for: .milliseconds(1800))
        show(.recording(.pushToTalk), on: overlay)
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
      _ name: String, _ phase: DictationPhase, for duration: Duration, _ overlay: DemoOverlay
    ) async {
      logger.info("\(name, privacy: .public)")
      show(phase, on: overlay)
      try? await Task.sleep(for: duration)
    }

    /// A waking microphone needs no call of its own on the notch: its core shows Connecting
    /// once the start outlasts the delay.
    static func show(_ phase: DictationPhase, wakingMicrophone: Bool = false, on overlay: DemoOverlay) {
      #if FEATURE_NOTCH
        overlay.show(phase)
      #else
        overlay.show(OverlayActivity(dictation: phase, wakingMicrophone: wakingMicrophone), from: .dictation)
      #endif
    }

    private static func feedMeter(_ overlay: DemoOverlay, for duration: Duration) async {
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
