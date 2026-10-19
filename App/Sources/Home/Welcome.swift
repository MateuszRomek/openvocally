import DesignSystem
import SwiftUI

/// No dictation yet. The shortcut is the page: its keys drawn large, staying down while it records.
/// The toggle leads, since it leaves room to pause and think. Until setup is done the keys stay
/// dimmed and finishing setup is the action.
struct Welcome: View {
  struct Shortcut: Equatable {
    enum Gesture { case hold, press, doubleTap }

    let gesture: Gesture
    let keys: [String]
  }

  let shortcut: Shortcut?
  let setup: SetupStep?
  let isRecording: Bool
  let open: (Screen) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: Space.xl.points)
      VStack(spacing: Space.xxl.points) {
        if let shortcut {
          caps(shortcut)
        }
        VStack(spacing: Space.s.points) {
          Text(title)
            .textStyle(.title2)
            .fontWeight(.semibold)
          Text(detail)
            .textStyle(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        actions
        Text("Your stats appear here after your first dictation.")
          .textStyle(.callout)
          .foregroundStyle(.tertiary)
          .padding(.top, Space.xl)
      }
      .frame(maxWidth: .infinity)
      Spacer(minLength: Space.xl.points)
      Spacer(minLength: 0)
    }
  }

  private func caps(_ shortcut: Shortcut) -> some View {
    HStack(spacing: Space.s.points) {
      ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
        KeyCap(key, isPressed: isRecording, size: .large)
      }
    }
    .disabled(setup != nil)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(shortcut.keys.joined(separator: " "))
  }

  @ViewBuilder private var actions: some View {
    if let setup {
      Button(setup.action) { open(setup.screen) }.appButton(.primary)
    } else if shortcut == nil {
      Button("Choose Shortcut…") { open(.settings) }.appButton(.primary)
    }
  }

  private var title: String {
    if setup != nil { return "Almost ready" }
    guard let shortcut else { return "Pick a shortcut to start dictating" }
    if isRecording {
      return shortcut.gesture == .hold ? "Listening. Let go to paste." : "Listening. Press again to paste."
    }
    return switch shortcut.gesture {
    case .hold: "Hold to dictate"
    case .press: "Press to dictate"
    case .doubleTap: "Double-tap to dictate"
    }
  }

  private var detail: String {
    if let setup { return setup.message }
    return switch shortcut?.gesture {
    case .hold: "Speak in any language. Let go and the text lands wherever you're typing."
    case .press: "Talk as long as you like. Press again and the text lands wherever you're typing."
    case .doubleTap: "Talk as long as you like. Double-tap again and the text lands wherever you're typing."
    case nil: "You'll hold it, speak, and let go to paste."
    }
  }
}
