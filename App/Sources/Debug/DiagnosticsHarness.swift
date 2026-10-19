#if DEBUG
  import AppKit
  import Diagnostics
  import Foundation
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "diagnostics-harness")

  /// Launch with `-diagnosticsExport <path>` to write the diagnostics file there and quit. With
  /// `-diagnosticsSecret <text>` it first logs that text with default privacy, the way a careless
  /// log line would carry a transcript, so a script can check the file leaves it out.
  @MainActor enum DiagnosticsHarness {
    static var isRequested: Bool {
      UserDefaults.standard.string(forKey: "diagnosticsExport") != nil
        || UserDefaults.standard.bool(forKey: "diagnosticsSettings")
    }

    static func run(_ model: AppModel) async {
      if UserDefaults.standard.bool(forKey: "diagnosticsSettings") {
        await showSettings(model)
        return
      }
      guard let path = UserDefaults.standard.string(forKey: "diagnosticsExport") else { return }
      let secret = UserDefaults.standard.string(forKey: "diagnosticsSecret")
      if let secret {
        logger.notice("Planted secret: \(secret)")
      }
      var started = ContinuousClock.now
      var file = await DiagnosticsFile.build(model.diagnosticsSnapshot())
      // The store shows a new entry after a short lag, and the script needs the planted line.
      for _ in 0..<20
      where secret != nil && !String(decoding: file.data, as: UTF8.self).contains("Planted secret") {
        try? await Task.sleep(for: .milliseconds(250))
        started = .now
        file = await DiagnosticsFile.build(model.diagnosticsSnapshot())
      }
      let elapsed = ContinuousClock.now - started
      do {
        try file.data.write(to: URL(filePath: path))
        logger.notice(
          "Diagnostics export written in \(String(describing: elapsed), privacy: .public): \(file.summary, privacy: .public)"
        )
      } catch {
        logger.error("Diagnostics export failed: \(String(describing: error), privacy: .public)")
      }
      NSApplication.shared.terminate(nil)
    }

    /// `-diagnosticsSettings YES` shows Settings in a window as tall as the screen, without
    /// activating the app, so a script can capture the Support section.
    private static func showSettings(_ model: AppModel) async {
      model.screen = .settings
      for _ in 0..<100 {
        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.frame.width >= 600 }),
          let visible = window.screen?.visibleFrame
        {
          window.setFrame(
            NSRect(x: visible.minX, y: visible.minY, width: 760, height: visible.height), display: true)
          try? await Task.sleep(for: .seconds(1))
          if let scroll = scrollViews(in: window.contentView).max(by: { $0.frame.height < $1.frame.height }),
            let document = scroll.documentView
          {
            document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
          }
          logger.notice("Diagnostics settings shown")
          return
        }
        if let opener = model.windowOpener { opener(id: "main") }
        try? await Task.sleep(for: .milliseconds(100))
      }
      logger.error("Diagnostics settings: no main window")
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
      guard let view else { return [] }
      return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }
  }
#endif
