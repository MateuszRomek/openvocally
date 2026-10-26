#if DEBUG
  import AppKit
  import DictationCore
  import Overlay
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "overlay-demo")

  /// Launch with `-overlayProbe <file>` to drive the overlay from a file a script rewrites:
  /// `<x> <y> <shown>`, the pointer in global screen points and 1 to show recording or 0 to
  /// hide. The overlay follows that pointer instead of the real cursor, so a script can aim
  /// at any display, virtual ones included, without moving the user's cursor.
  @MainActor enum OverlayProbe {
    static var pointer = NSEvent.mouseLocation

    static var path: String? { UserDefaults.standard.string(forKey: "overlayProbe") }
    static var isRequested: Bool {
      #if FEATURE_NOTCH
        if NotchProbe.path != nil { return true }
      #endif
      return path != nil
    }

    static func run(_ overlay: DemoOverlay) async {
      #if FEATURE_NOTCH
        if NotchProbe.path != nil {
          await NotchProbe.run(overlay)
          return
        }
      #endif
      guard let path else { return }
      var shown = false
      logger.info("probe ready")
      while !Task.isCancelled {
        let fields = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
          .split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        if fields.count == 3 {
          pointer = CGPoint(x: fields[0], y: fields[1])
          let wanted = fields[2] == 1
          if wanted != shown {
            shown = wanted
            logger.info("probe shown \(wanted, privacy: .public)")
            OverlayDemo.show(wanted ? .recording(.toggle) : .idle, on: overlay)
          }
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  #if FEATURE_NOTCH
    /// Launch with `-notchProbe <file>` to show one notch scene at a time from a file a script
    /// rewrites: `<x> <y> <scene>`, the pointer in global screen points and a scene name from
    /// `scenes`. Once the scene has settled it logs the display and the panel's window number,
    /// so the script can capture that panel alone.
    @MainActor enum NotchProbe {
      static var path: String? { UserDefaults.standard.string(forKey: "notchProbe") }

      private static let failures: [(String, DictationFailureReason)] = [
        ("microphonePermissionDenied", .microphonePermissionDenied),
        ("noInputDevice", .captureError(.noInputDevice)),
        ("startTimedOut", .captureError(.startTimedOut)),
        ("stopTimedOut", .captureError(.stopTimedOut)),
        ("deviceLost", .captureError(.deviceLost)),
        ("captureFailed", .captureError(.captureFailed)),
        ("transcriptionError", .transcriptionError),
        ("noSpeech", .noSpeech),
        ("modelNotInstalled", .modelNotInstalled),
        ("pasteNotSupported", .pasteNotSupported),
        ("pastePermissionDenied", .pastePermissionDenied),
        ("pasteRuntimeError", .pasteRuntimeError),
        ("nothingToPaste", .nothingToPaste),
        ("manualPasteExpired", .manualPasteExpired),
      ]

      /// Each scene's phases from idle. A notice follows a recording, the way it arrives.
      static func phases(_ scene: String) -> [DictationPhase]? {
        switch scene {
        case "hidden": return []
        case "connecting", "starting": return [.starting(.pushToTalk)]
        case "recording": return [.recording(.toggle)]
        case "stopping": return [.recording(.toggle), .stopping]
        case "transcribing": return [.recording(.toggle), .transcribing]
        case "pasting": return [.recording(.toggle), .pasting]
        case "complete": return [.recording(.toggle), .complete]
        case "manual-paste":
          let until = HostTime.now().advanced(by: DictationMachine.manualPasteWindow)
          return [.recording(.toggle), .awaitingManualPaste(until: until)]
        default:
          return failures.first { "failed-\($0.0)" == scene }.map { [.recording(.toggle), .failed($0.1)] }
        }
      }

      static func run(_ overlay: NotchHost) async {
        guard let path else { return }
        var current: String?
        var meter: Task<Void, Never>?
        logger.info("notch probe ready")
        while !Task.isCancelled {
          let fields = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
          if fields.count == 3, let x = Double(fields[0]), let y = Double(fields[1]), fields[2] != current,
            let phases = phases(fields[2])
          {
            let scene = fields[2]
            current = scene
            meter?.cancel()
            OverlayProbe.pointer = CGPoint(x: x, y: y)
            overlay.show(.idle)
            try? await Task.sleep(for: .milliseconds(400))
            for phase in phases { overlay.show(phase) }
            if scene == "recording" {
              meter = Task {
                while !Task.isCancelled {
                  overlay.meter(bands)
                  try? await Task.sleep(for: .milliseconds(50))
                }
              }
            }
            let settle = ["connecting": 1000, "starting": 150][scene] ?? 600
            try? await Task.sleep(for: .milliseconds(settle))
            let shown = overlay.shownPanel
            let drawn = overlay.drawnDisplays.map(String.init).joined(separator: ",")
            logger.info(
              """
              notch probe shown \(scene, privacy: .public) display \(shown.map { String($0.display) } ?? "none", privacy: .public) \
              drawn \(drawn.isEmpty ? "none" : drawn, privacy: .public) \
              window \(shown.map { String($0.window) } ?? "none", privacy: .public)
              """)
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
      }

      private static let bands: [Float] = (0..<20).map { band in
        Float(max(0.05, 0.9 - abs(Double(band) - 9.5) / 11))
      }
    }
  #endif
#endif
