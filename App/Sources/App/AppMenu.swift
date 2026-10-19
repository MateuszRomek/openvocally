import AppKit
import DictationCore
import SwiftUI

/// One list renders both the menu bar extra and the Dock menu.
enum AppMenuItem: Int, CaseIterable {
  case toggleDictation
  case pasteLast
  case openWindow
  case settings
  case checkForUpdates
  case quit

  /// The Dock already offers its own Open and Quit.
  static let dock: [AppMenuItem] = [.toggleDictation, .pasteLast, .settings]

  static let menuBarShownKey = "menuBarExtra.shown"

  func title(phase: DictationPhase, update: Updates.State = .none) -> String {
    switch self {
    case .toggleDictation:
      switch phase.intent(for: .toggle) {
      case .stop, .cancel: "Stop Dictation"
      default: "Start Dictation"
      }
    case .pasteLast: "Paste Last Transcript"
    case .openWindow: "Open OpenVocally"
    case .settings: "Settings…"
    case .checkForUpdates:
      switch update {
      case .none: "Check for Updates…"
      case .available: "Update Available…"
      case .readyToInstall: "Restart to Update"
      }
    case .quit: "Quit OpenVocally"
    }
  }

  var startsGroup: Bool { self == .openWindow || self == .quit }
}

struct MenuBarMenu: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ForEach(AppMenuItem.allCases, id: \.self) { item in
      if item != .checkForUpdates || model.updates.isAvailable {
        if item.startsGroup { Divider() }
        Button(item.title(phase: model.feedback.phase, update: model.updates.state)) {
          model.windowOpener = openWindow
          model.perform(item)
        }
        .disabled(
          item == .checkForUpdates && model.updates.state == .none && !model.updates.canCheckForUpdates)
      }
    }
  }
}
