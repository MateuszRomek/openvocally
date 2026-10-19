import DictationCore
import os

/// Signpost events in category "latency". Durations travel as public metadata because a
/// signpost cannot be backdated to the key event's timestamp. scripts/latency/dictation-latency.sh
/// reads them.
public enum Latency {
  private static let signposter = OSSignposter(subsystem: "com.openvocally.app", category: "latency")

  /// What started the session whose feedback is measured.
  public enum Trigger: Sendable {
    /// A chord, toggle or menu item.
    case press
    /// A one-key hold. Its own mark, so the confirm delay never mixes into LB-01.
    case hold
  }

  /// LB-01 end. The app calls it right after the overlay drew a session's first recording
  /// frame. A one-key hold reports "LB-01-hold".
  public static func feedbackShown(pressedAt: HostTime, trigger: Trigger) {
    let ms = HostTime.now().milliseconds(since: pressedAt)
    switch trigger {
    case .press:
      signposter.emitEvent("LB-01", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    case .hold:
      signposter.emitEvent("LB-01-hold", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    }
  }

  static func emit(_ mark: LatencyMark) {
    switch mark {
    case .releaseToPasted(let duration):
      let ms = milliseconds(duration)
      signposter.emitEvent("LB-02", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    }
  }

  static func captureRequested(pressedAt: HostTime) {
    let ms = HostTime.now().milliseconds(since: pressedAt)
    signposter.emitEvent(
      "pressToCaptureRequested", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
  }

  enum Stage {
    case transcribe
    case process
  }

  static func stage(_ stage: Stage, since start: HostTime) {
    let ms = HostTime.now().milliseconds(since: start)
    switch stage {
    case .transcribe:
      signposter.emitEvent("LB-02-transcribe", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    case .process:
      signposter.emitEvent("LB-02-process", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    }
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
  }
}
