import AppKit

/// A pane of System Settings' Privacy & Security, where a denied permission is turned back on.
enum PrivacyPane: String {
  case microphone = "Privacy_Microphone"
  case accessibility = "Privacy_Accessibility"

  func open() {
    guard
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
