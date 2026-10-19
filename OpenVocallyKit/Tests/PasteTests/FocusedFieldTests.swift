import Testing

@testable import Paste

struct FocusedFieldTests {
  @Test(arguments: [
    FocusSnapshot(bundleIdentifier: "com.apple.finder", role: "AXGroup", subrole: "AXDesktop"),
    FocusSnapshot(bundleIdentifier: "com.apple.Safari", role: "AXButton"),
    FocusSnapshot(bundleIdentifier: "com.apple.systempreferences", role: "AXCheckBox"),
    FocusSnapshot(bundleIdentifier: "com.apple.finder", role: "AXOutline"),
    FocusSnapshot(bundleIdentifier: "com.apple.finder", role: "AXList"),
  ])
  func `focus that never takes text needs a manual paste`(snapshot: FocusSnapshot) {
    #expect(FocusedField(snapshot) == .noTextField)
  }

  @Test(arguments: [
    nil,
    FocusSnapshot(
      bundleIdentifier: "com.anthropic.claudefordesktop", role: "AXTextArea", valueIsSettable: true),
    FocusSnapshot(bundleIdentifier: "org.mozilla.firefox", role: "AXWindow"),
    FocusSnapshot(bundleIdentifier: "com.cmuxterm.app", role: "AXWindow"),
    FocusSnapshot(bundleIdentifier: "com.apple.finder", role: "AXTextField", valueIsSettable: true),
    FocusSnapshot(bundleIdentifier: "com.apple.mail", role: "AXOutline"),
    FocusSnapshot(bundleIdentifier: "com.apple.Safari", role: "AXButton", valueIsSettable: true),
  ])
  func `anything that might take text gets the auto-paste`(snapshot: FocusSnapshot?) {
    #expect(FocusedField(snapshot) == .unknown)
  }
}
