import AppKit
import DesignSystem

/// Light, dark, or whatever the Mac uses. Applies to every window, including the overlay.
enum AppTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let defaultsKey = "appTheme"

  var id: Self { self }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  static var saved: AppTheme {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppTheme.init(rawValue:)) ?? .system
  }

  @MainActor func apply() {
    switch self {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }
}

extension WindowBackground {
  static let defaultsKey = "windowBackground"
}
