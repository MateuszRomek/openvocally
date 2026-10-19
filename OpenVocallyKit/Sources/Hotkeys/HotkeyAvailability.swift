/// Whether the shortcuts work right now, shown in Settings. The platform is always
/// supported, because the app runs only on Apple Silicon Macs.
public enum HotkeyAvailability: Equatable, Sendable {
  case starting
  case needsAccessibility
  case failed
  case ready

  public init(_ error: HotkeysStartError) {
    switch error {
    case .accessibilityNotGranted: self = .needsAccessibility
    case .tapCreationFailed: self = .failed
    }
  }
}
