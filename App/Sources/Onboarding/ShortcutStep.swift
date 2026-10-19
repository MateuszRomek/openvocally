import SwiftUI

/// The toggle and push to talk, each with its recorder.
struct ShortcutStep: View {
  let shortcuts: Shortcuts

  var body: some View {
    Form {
      ShortcutsSection(shortcuts: shortcuts, actions: [.toggle, .pushToTalk])
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .scrollContentBackground(.hidden)
    .frame(height: Self.formHeight)
  }

  static let formHeight: CGFloat = 200
}
