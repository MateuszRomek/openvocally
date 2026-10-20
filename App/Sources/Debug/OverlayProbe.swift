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
    private(set) static var pointer = NSEvent.mouseLocation

    static var path: String? { UserDefaults.standard.string(forKey: "overlayProbe") }
    static var isRequested: Bool { path != nil }

    static func run(_ overlay: OverlayHost) async {
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
            overlay.show(
              OverlayActivity(dictation: wanted ? .recording(.toggle) : .idle), from: .dictation)
          }
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }
#endif
