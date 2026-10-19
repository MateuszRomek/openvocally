import AppKit
import ApplicationServices

/// What the frontmost app reports as focused, read through Accessibility.
struct FocusSnapshot: Sendable, Equatable {
  var bundleIdentifier: String?
  var role: String?
  var subrole: String?
  var valueIsSettable = false
}

/// Whether a ⌘V can land in text. Only a clear `noTextField` changes anything; apps that
/// report focus poorly, such as Electron apps and terminals that report their window, read as
/// `unknown` and get the auto-paste as before.
enum FocusedField: Sendable, Equatable {
  case noTextField
  case unknown

  /// Roles that never take typed text, so a paste into them does nothing.
  static let controlRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
    "AXImage", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXLink", "AXColorWell",
  ]

  /// Finder's file views. Its rename and search fields are text fields and stay `unknown`.
  static let finderBrowsingRoles: Set<String> = [
    "AXList", "AXOutline", "AXBrowser", "AXTable", "AXGroup", "AXScrollArea",
  ]

  init(_ snapshot: FocusSnapshot?) {
    guard let snapshot, !snapshot.valueIsSettable else {
      self = .unknown
      return
    }
    if snapshot.subrole == "AXDesktop" {
      self = .noTextField
    } else if let role = snapshot.role, Self.controlRoles.contains(role) {
      self = .noTextField
    } else if snapshot.bundleIdentifier == "com.apple.finder", let role = snapshot.role,
      Self.finderBrowsingRoles.contains(role)
    {
      self = .noTextField
    } else {
      self = .unknown
    }
  }
}

/// Accessibility reads of the frontmost app's focused element. The first read of an app costs
/// 16 to 39 ms and later reads under 1 ms (measured across 10 apps on one Mac), so the app
/// warms each app as it comes to the front.
public enum FocusProbe {
  /// Caps a read of a hung app. Past it the field counts as `unknown` and the paste goes ahead.
  static let messagingTimeout: Float = 0.05

  static func read() -> FocusSnapshot? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    guard let focused: AXUIElement = attribute(kAXFocusedUIElementAttribute, of: element) else { return nil }
    AXUIElementSetMessagingTimeout(focused, messagingTimeout)
    var settable = DarwinBoolean(false)
    let settableResult = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
    return FocusSnapshot(
      bundleIdentifier: app.bundleIdentifier,
      role: attribute(kAXRoleAttribute, of: focused),
      subrole: attribute(kAXSubroleAttribute, of: focused),
      valueIsSettable: settableResult == .success && settable.boolValue)
  }

  /// Opens the Accessibility connection to an app so the read on the paste path is warm.
  public static func warm(processIdentifier: pid_t) {
    let element = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    let _: AXUIElement? = attribute(kAXFocusedUIElementAttribute, of: element)
  }

  private static func attribute<Value>(_ name: String, of element: AXUIElement) -> Value? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? Value
  }
}
