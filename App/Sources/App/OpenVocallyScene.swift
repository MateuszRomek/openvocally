import DesignSystem
import SwiftUI

/// Every window and the menu bar extra. The `@main` type in `OpenVocallyApp.swift` only hosts
/// this scene, so another build can replace that one file and keep the rest.
struct OpenVocallyScene: Scene {
  let model: AppModel
  @AppStorage(AppMenuItem.menuBarShownKey) private var menuBarShown = true

  var body: some Scene {
    Window("OpenVocally", id: "main") {
      MainWindow(model: model)
        .tint(.token(.accent))
    }
    .defaultSize(width: 900, height: 670)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(Onboarding.neededAtLaunch ? .suppressed : .automatic)
    .commands {
      CommandGroup(replacing: .appSettings) { SettingsCommand(model: model) }
      if model.updates.isAvailable {
        CommandGroup(after: .appInfo) {
          Button("Check for Updates…") { model.updates.checkForUpdates() }
            .disabled(!model.updates.canCheckForUpdates)
        }
      }
    }
    Window("Welcome to OpenVocally", id: Onboarding.windowID) {
      OnboardingView(model: model)
        .id(model.onboardingRun)
        .tint(.token(.accent))
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)
    .defaultLaunchBehavior(Onboarding.neededAtLaunch ? .presented : .suppressed)
    .restorationBehavior(.disabled)
    // Bound straight to $menuBarShown, SwiftUI writes the same value back on every update and
    // rebuilds the main menu in a loop that pins the main thread.
    MenuBarExtra(
      isInserted: Binding(get: { menuBarShown }, set: { if $0 != menuBarShown { menuBarShown = $0 } })
    ) {
      MenuBarMenu(model: model)
    } label: {
      Image("MenuBarLogo").accessibilityLabel("OpenVocally")
    }
    .menuBarExtraStyle(.menu)
    #if DEBUG
      Window("Design Gallery", id: "design-gallery") {
        DesignGallery()
          .tint(.token(.accent))
      }
      .defaultSize(width: 1440, height: 900)
      .defaultLaunchBehavior(
        UserDefaults.standard.bool(forKey: "designGallery") ? .presented : .automatic)
    #endif
  }
}

/// Command-comma opens Settings inside the main window.
private struct SettingsCommand: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Settings…") {
      model.windowOpener = openWindow
      model.perform(.settings)
    }
    .keyboardShortcut(",")
  }
}
