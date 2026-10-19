import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel(extensions: .standard)

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppTheme.saved.apply()
    model.start()
  }

  /// Closing the window hides it; dictation keeps running.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    guard !hasVisibleWindows else { return true }
    model.perform(.openWindow)
    return false
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    for item in AppMenuItem.dock {
      let entry = NSMenuItem(
        title: item.title(phase: model.feedback.phase), action: #selector(performDockItem(_:)),
        keyEquivalent: "")
      entry.target = self
      entry.tag = item.rawValue
      menu.addItem(entry)
    }
    return menu
  }

  @objc private func performDockItem(_ sender: NSMenuItem) {
    guard let item = AppMenuItem(rawValue: sender.tag) else { return }
    model.perform(item)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await model.shutDown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
