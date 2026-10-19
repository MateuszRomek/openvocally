import CoreGraphics
import DictationCore

protocol PasteKeystroke: Sendable {
  /// Posts Cmd+V down and up and returns when the key-down was posted, which is when the
  /// target app pastes. Nil when the events cannot be created.
  func postCommandV() async -> HostTime?
}

/// A private-state source keeps modifiers still held from the push-to-talk chord out of the
/// paste; a held Shift would turn it into Paste and Match Style.
struct CGPasteKeystroke: PasteKeystroke {
  private static let keyV: CGKeyCode = 0x09

  func postCommandV() async -> HostTime? {
    guard
      let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: false)
    else { return nil }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cgSessionEventTap)
    let posted = HostTime.now()
    try? await Task.sleep(for: .milliseconds(8))
    up.post(tap: .cgSessionEventTap)
    return posted
  }
}
