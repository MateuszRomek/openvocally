import DesignSystem
import SwiftUI

/// The last step: a real dictation through the whole pipeline into a field of this window.
struct TryItStep: View {
  let model: AppModel
  @Binding var done: Bool
  let download: ModelDownloadStatus
  let retry: () -> Void
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: Space.m.points) {
      TextField("Your words appear here", text: $text, axis: .vertical)
        .lineLimit(Self.lines, reservesSpace: true)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
      readiness
    }
    .frame(maxWidth: StepHeader.textWidth)
    .motion(.onboardingStep, value: done)
    .onAppear { focused = true }
    .onChange(of: text) { _, value in
      guard landing, !done, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      done = true
    }
  }

  /// Only an edit while a dictation pastes counts, so typing or a paste of the user's own
  /// clipboard never celebrates. `.complete` shows for 650 ms after the paste, which covers
  /// the ⌘V reaching the field after the pipeline reports it.
  private var landing: Bool {
    switch model.feedback.phase {
    case .pasting, .complete: true
    default: false
    }
  }

  static let lines = 4

  @ViewBuilder private var readiness: some View {
    if done {
      EmptyView()
    } else if !model.shortcuts.accessibilityGranted {
      Banner(
        tone: .attention, title: "Dictation needs Accessibility",
        message: "It pastes your words where you type."
      ) {
        Button("Open System Settings") { PrivacyPane.accessibility.open() }
          .appButton(size: .small)
      }
    } else if model.input.access != .granted {
      Banner(
        tone: .attention, title: "Dictation needs the microphone",
        message: model.input.access == .notDetermined
          ? "Allow it so OpenVocally can hear you." : "Turn on OpenVocally in System Settings."
      ) {
        if model.input.access == .notDetermined {
          Button("Allow") { Task { await model.input.requestAccess() } }
            .appButton(.primary, size: .small)
        } else {
          Button("Open System Settings") { PrivacyPane.microphone.open() }
            .appButton(size: .small)
        }
      }
    } else if download != .hidden, download != .ready {
      ModelDownloadStatusLine(status: download, retry: retry)
    } else if model.models.needsModel {
      StatusRow(title: "No speech model yet", detail: "Download one from Models later.", status: .attention)
    }
  }
}
