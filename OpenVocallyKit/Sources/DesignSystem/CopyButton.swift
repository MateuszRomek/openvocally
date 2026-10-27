import SwiftUI

/// Copies on a press and confirms it: the symbol morphs into a green checkmark under `confirm`,
/// holds for `Motion.confirmationHold` and goes back under the faster `confirmEnd`. A press
/// during the hold restarts it. The press itself shrinks the button under `press`. Under Reduce
/// Motion the symbols crossfade and nothing scales.
public struct CopyButton: View {
  private let title: String
  private let showsTitle: Bool
  private let copy: () async -> Bool
  @Binding private var copied: Bool
  @State private var hold: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `copy` returns whether it put something on the pasteboard; when it didn't, the checkmark
  /// goes back at once. `copied` lets the parent view keep the button on screen while it confirms.
  public init(
    _ title: String = "Copy", showsTitle: Bool = false, copied: Binding<Bool>,
    copy: @escaping () async -> Bool
  ) {
    self.title = title
    self.showsTitle = showsTitle
    self._copied = copied
    self.copy = copy
  }

  public var body: some View {
    Button(action: press) {
      Label {
        Text(title)
      } icon: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .foregroundStyle(copied ? AnyShapeStyle(SemanticColor.success.color) : AnyShapeStyle(.secondary))
          .contentTransition(
            reduceMotion
              ? .opacity
              : .symbolEffect(
                .replace.magic(fallback: .downUp.byLayer),
                options: .nonRepeating.speed(Motion.symbolSpeed))
          )
      }
      .labelStyle(TitleVisibility(showsTitle: showsTitle))
    }
    .buttonStyle(PressFeedbackStyle())
    .help(copied ? "Copied" : title)
    // The icon-only style draws no title, and help text is not a name VoiceOver reads.
    .accessibilityLabel(copied ? "Copied" : title)
    .onDisappear {
      hold?.cancel()
      hold = nil
      copied = false
    }
  }

  /// The checkmark shows on the press itself, not after the async copy, so the feedback never
  /// waits on a database read. A failed copy takes it back at once.
  private func press() {
    hold?.cancel()
    withAnimation(Motion.confirm.resolved(reduceMotion: reduceMotion)) { copied = true }
    hold = Task {
      let succeeded = await copy()
      guard !Task.isCancelled else { return }
      if succeeded { try? await Task.sleep(for: Motion.confirmationHold) }
      guard !Task.isCancelled else { return }
      withAnimation(Motion.confirmEnd.resolved(reduceMotion: reduceMotion)) { copied = false }
    }
  }
}

private struct TitleVisibility: LabelStyle {
  let showsTitle: Bool

  func makeBody(configuration: Configuration) -> some View {
    if showsTitle {
      HStack(spacing: Space.xs.points) {
        configuration.icon
        configuration.title
      }
    } else {
      configuration.icon
    }
  }
}
