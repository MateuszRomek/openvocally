import DesignSystem
import SwiftUI

/// Microphone and Accessibility in one card, each with its own Allow, so the user asks for
/// one system prompt at a time and sees each one turn on.
struct PermissionsCard: View {
  let model: AppModel
  @Binding var accessibilityRequested: Bool
  @State private var requestingMicrophone = false

  var body: some View {
    Card {
      VStack(spacing: Space.m.points) {
        PermissionRow(
          symbol: "mic.fill", title: "Microphone", why: "Hears you while you dictate.",
          state: microphone, allow: allowMicrophone,
          openSettings: { PrivacyPane.microphone.open() })
        Divider()
        PermissionRow(
          symbol: "accessibility", title: "Accessibility",
          why: "Lets the shortcut work everywhere and pastes where you type.",
          state: accessibility, allow: allowAccessibility,
          openSettings: { PrivacyPane.accessibility.open() })
      }
    }
    .frame(maxWidth: Self.width)
  }

  private var microphone: PermissionRow.State {
    switch model.input.access {
    case .granted: .granted
    case .denied: .denied
    case .notDetermined: requestingMicrophone ? .asking : .notAsked
    }
  }

  private var accessibility: PermissionRow.State {
    if model.shortcuts.accessibilityGranted { return .granted }
    return accessibilityRequested ? .waiting : .notAsked
  }

  private func allowMicrophone() {
    requestingMicrophone = true
    Task {
      await model.input.requestAccess()
      requestingMicrophone = false
    }
  }

  private func allowAccessibility() {
    model.shortcuts.requestAccessibility()
    accessibilityRequested = true
  }

  static let width: CGFloat = 460
}

/// One permission: what it is, why, and a control that follows its state.
private struct PermissionRow: View {
  enum State: Equatable {
    case notAsked
    /// The system alert is up.
    case asking
    /// Asked; the user still has to switch it on in System Settings.
    case waiting
    case denied
    case granted
  }

  let symbol: String
  let title: String
  let why: String
  let state: State
  let allow: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(spacing: Space.m.points) {
      Image(systemName: symbol)
        .textStyle(.title3)
        .foregroundStyle(.token(.accent))
        .frame(width: Self.symbolWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Space.xxs.points) {
        Text(title).textStyle(.headline)
        Text(why)
          .textStyle(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Space.s.points)
      control
        .id(state)
        .transition(.blurReplace)
    }
    .motion(.confirm, value: state)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var control: some View {
    switch state {
    case .notAsked:
      Button("Allow", action: allow).appButton(.primary, size: .small)
    case .asking:
      ProgressView().controlSize(.small)
    case .waiting:
      HStack(spacing: Space.s.points) {
        ProgressView().controlSize(.small)
        Button("Open System Settings", action: openSettings).appButton(size: .small)
      }
    case .denied:
      HStack(spacing: Space.s.points) {
        StatusIcon(.attention)
        Button("Open System Settings", action: openSettings).appButton(size: .small)
      }
    case .granted:
      Label {
        Text("On").textStyle(.body)
      } icon: {
        StatusIcon(.ok)
      }
    }
  }

  static let symbolWidth: CGFloat = 28
}
