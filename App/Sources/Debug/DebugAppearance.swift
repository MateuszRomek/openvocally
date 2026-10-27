#if DEBUG
  import AppKit

  /// `-debugAppearance light|dark` sets the app's appearance at launch, so a screenshot run forces
  /// a look without changing the user's system settings. There is no Increase Contrast case:
  /// `NSAppearance(named: .accessibilityHighContrastAqua)` returns plain Aqua, so only the system
  /// setting turns it on.
  enum DebugAppearance: String {
    case light, dark

    var name: NSAppearance.Name {
      switch self {
      case .light: .aqua
      case .dark: .darkAqua
      }
    }

    @MainActor static func applyFromArguments() {
      guard let raw = UserDefaults.standard.string(forKey: "debugAppearance"),
        let appearance = Self(rawValue: raw)
      else { return }
      NSApplication.shared.appearance = NSAppearance(named: appearance.name)
    }
  }
#endif
