import SwiftUI

/// The only file another build replaces. It supplies its own `@main` type and its own
/// `AppExtensions.standard`, and compiles every other file in `App/Sources` unchanged.
@main
struct OpenVocallyApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    OpenVocallyScene(model: delegate.model)
  }
}

extension AppExtensions {
  /// This build ships no add-ons.
  static let standard = AppExtensions()
}
