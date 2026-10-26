import DictationCore
import Foundation

extension OverlayActivity {
  /// Longer than every measured mic start (54 to 147 ms on AirPods, about 50 ms built in).
  public static let connectingDelay: Duration = .milliseconds(300)

  /// nil when dictation shows nothing: idle, and a cancel, whose collapse and cue are the
  /// feedback.
  /// `now` and `hostNow` convert the manual paste deadline from the dictation clock.
  /// `wakingMicrophone` names a start that is still waiting for the mic after
  /// `connectingDelay`; a faster start shows no label of its own, so it never flashes.
  public init?(
    dictation phase: DictationPhase, wakingMicrophone: Bool = false, now: Date = .now,
    hostNow: HostTime = .now()
  ) {
    switch phase {
    case .idle:
      return nil
    case .starting:
      if wakingMicrophone {
        self.init(glyph: nil, status: "Connecting", body: .compact(.status))
      } else {
        self.init(glyph: nil, status: "Recording", body: .compact(.bars(.pulse)))
      }
    case .recording:
      self.init(glyph: nil, status: "Recording", body: .compact(.bars(.live)))
    case .stopping, .transcribing:
      self.init(glyph: nil, status: "Transcribing", body: .compact(.bars(.sweep)))
    case .pasting:
      self.init(glyph: nil, status: "Pasting", body: .compact(.bars(.sweep)))
    case .complete:
      self.init(glyph: .success, status: "Pasted", body: .compact(.status))
    case .awaitingManualPaste(let until):
      let alert = OverlayAlert(
        "Copied. Paste with", keys: ["⌘V"],
        countdown: Countdown(
          ends: Self.wallClock(until, now: now, hostNow: hostNow),
          total: DictationMachine.manualPasteWindow))
      self.init(glyph: nil, status: "Ready to paste", body: .alert(alert))
    case .failed(let reason):
      guard let message = Self.message(for: reason) else { return nil }
      let alert = OverlayAlert(message)
      switch reason {
      case .manualPasteExpired:
        self.init(glyph: nil, status: "Not pasted", body: .alert(alert))
      case .nothingToPaste:
        self.init(glyph: .attention, status: "Nothing to paste", body: .alert(alert))
      default:
        self.init(glyph: .attention, status: "Failed", body: .alert(alert))
      }
    }
  }

  /// The overlay line for each failure reason. nil for a cancel, which shows nothing.
  static func message(for reason: DictationFailureReason) -> StaticString? {
    reason.overlayMessage
  }
}

extension OverlayActivity {
  /// A deadline already past ends now.
  static func wallClock(_ until: HostTime, now: Date, hostNow: HostTime) -> Date {
    now.addingTimeInterval(until > hostNow ? until.seconds(since: hostNow) : 0)
  }
}

extension DictationFailureReason {
  /// The overlay line for this failure, shared by the pill and the notch. nil for a cancel,
  /// which shows nothing.
  var overlayMessage: StaticString? {
    switch self {
    case .aborted: nil
    case .microphonePermissionDenied: "Microphone access needed"
    case .captureError(.noInputDevice): "No microphone found"
    case .captureError(.startTimedOut): "Microphone didn't start"
    case .captureError(.stopTimedOut): "Recording didn't stop"
    case .captureError(.deviceLost): "Microphone disconnected"
    case .captureError(.captureFailed): "Couldn't record"
    case .transcriptionError: "Couldn't transcribe"
    case .noSpeech: "No speech detected"
    case .modelNotInstalled: "Download a model in Models"
    case .pasteNotSupported: "Can't paste here"
    case .pastePermissionDenied: "Accessibility access needed"
    case .pasteRuntimeError: "Couldn't paste"
    case .nothingToPaste: "Nothing to paste yet"
    case .manualPasteExpired: "Saved to Transcripts"
    }
  }
}
