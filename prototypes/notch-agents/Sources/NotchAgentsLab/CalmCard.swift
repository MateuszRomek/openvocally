import SwiftUI

/// The start card with the card itself as the input: a bare prompt, the settings as one quiet line,
/// shortcuts only while left ⌘ is held, and the two actions as key hints.
struct CalmCard: View {
  @Bindable var lab: Lab

  /// Every row starts at the same left edge as the prompt's text.
  static let inset: CGFloat = 14

  var body: some View {
    if let draft = lab.draft {
      VStack(alignment: .leading, spacing: 12) {
        if let step = draft.launchStep {
          LaunchChecklist(steps: lab.launchSteps(draft), done: step)
            .padding(.horizontal, Self.inset - Tokens.dropInset)
        } else {
          CalmPrompt(lab: lab, draft: draft)
          SettingsLine(lab: lab, draft: draft)
          if lab.openControl != nil {
            OptionList(lab: lab, settings: draft.settings)
          }
          CalmFooter(lab: lab, draft: draft)
        }
      }
      .padding(.horizontal, Tokens.dropInset)
      .padding(.top, 6)
      .padding(.bottom, Tokens.dropInset)
    }
  }
}

/// The top row's trailing wing while the calm card is open: the project the new thread runs in.
/// A click opens the project list. It stays short, because both wings grow to the wider one.
struct CalmHeader: View {
  @Bindable var lab: Lab
  let project: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "folder").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
      Text(project).foregroundStyle(.white).lineLimit(1)
      if lab.shortcutsHeld { KeyCap(text: shortcut).transition(.opacity) }
    }
    .font(Tokens.label)
    .fixedSize()
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color.white.opacity(lab.focusedControl == .project ? 0.45 : 0), lineWidth: 1)
        .fill(Color.white.opacity(lab.openControl == .project ? 0.14 : 0))
    }
    .contentShape(Rectangle())
    .onTapGesture { lab.tap(.project) }
  }

  private var shortcut: String {
    lab.pickerKeys == .chords ? "⇧⌘\(CardControl.project.chordLetter)" : "⌘1"
  }
}

private struct CalmPrompt: View {
  @Bindable var lab: Lab
  let draft: StartDraft
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if isListening {
        HStack(spacing: 8) {
          Bars(levels: lab.levels, live: true)
          Text("Listening").font(.system(size: 15)).foregroundStyle(.white.opacity(0.55))
          Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
      } else if lab.promptStyle == .field || lab.editingPrompt {
        TextField(
          text: Binding(get: { lab.draft?.prompt ?? "" }, set: { lab.draft?.prompt = $0 }),
          prompt: Text("What should the agent do?").foregroundStyle(.white.opacity(0.4)), axis: .vertical
        ) {
          Text("Prompt")
        }
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .focused($focused)
      } else {
        Text(draft.prompt.isEmpty ? "What should the agent do?" : draft.prompt)
          .foregroundStyle(draft.prompt.isEmpty ? .white.opacity(0.4) : .white)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { lab.editingPrompt = true }
      }
    }
    .font(.system(size: 15))
    .foregroundStyle(.white)
    .lineSpacing(3)
    .padding(.horizontal, CalmCard.inset - Tokens.dropInset)
    .onAppear { focused = wantsFocus }
    .onChange(of: wantsFocus) { _, wants in focused = wants }
  }

  private var wantsFocus: Bool {
    !lab.passive && lab.focusedControl == nil && (lab.promptStyle == .field || lab.editingPrompt)
  }

  private var isListening: Bool {
    if case .recording(let target) = lab.dictation, target == Lab.newThreadTarget { return true }
    return false
  }
}

/// Who runs the thread on the left, where it runs on the right, as text rather than buttons.
private struct SettingsLine: View {
  @Bindable var lab: Lab
  let draft: StartDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        ForEach(Array(CardControl.agent.enumerated()), id: \.element) { index, control in
          if index > 0 { Separator() }
          token(control, symbol: control == .provider ? draft.settings.provider.symbol : nil)
        }
        Spacer(minLength: 12)
        token(.worktree, symbol: "arrow.triangle.branch")
      }
      if draft.settings.worktree {
        HStack(spacing: 0) {
          TextField(
            "Branch",
            text: Binding(get: { lab.draft?.branch ?? "" }, set: { lab.draft?.branchOverride = $0 })
          )
          .textFieldStyle(.plain)
          .font(.system(size: 11.5).monospaced())
          .foregroundStyle(.white.opacity(0.55))
          .fixedSize()
          .padding(.leading, 6)
          Separator()
          token(.base, symbol: nil)
          Spacer(minLength: 12)
          if let setup = Lab.project(draft.settings.project).setup {
            Text("runs \(setup) first").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.35))
              .padding(.trailing, 6)
          }
        }
      }
    }
    .padding(.horizontal, CalmCard.inset - Tokens.dropInset - 6)
  }

  private func token(_ control: CardControl, symbol: String?) -> some View {
    Token(
      text: text(control), symbol: symbol,
      changed: control != .worktree && differs(control),
      shortcut: lab.shortcutsHeld ? shortcut(control) : nil,
      emphasis: lab.openControl == control ? .open : lab.focusedControl == control ? .focused : .rest,
      enabled: lab.isEnabled(control)
    )
    .onTapGesture { if lab.isEnabled(control) { lab.tap(control) } }
  }

  private func text(_ control: CardControl) -> String {
    switch control {
    case .worktree: lab.isEnabled(.worktree) ? (draft.settings.worktree ? "Worktree" : "Local") : "Not a git folder"
    default: lab.value(control, draft.settings)
    }
  }

  /// A dot marks what differs from the last thread you started.
  private func differs(_ control: CardControl) -> Bool {
    lab.raw(control, draft.settings) != lab.raw(control, lab.lastSettings)
  }

  private func shortcut(_ control: CardControl) -> String? {
    switch lab.pickerKeys {
    case .numbered: "⌘\(control.rawValue + 1)"
    case .tab: nil
    case .chords: "⇧⌘\(control.chordLetter)"
    }
  }
}

private struct Separator: View {
  var body: some View {
    Text("·").font(.system(size: 12)).foregroundStyle(.white.opacity(0.25)).padding(.horizontal, 1)
  }
}

private struct Token: View {
  enum Emphasis { case rest, focused, open }

  let text: String
  let symbol: String?
  let changed: Bool
  let shortcut: String?
  let emphasis: Emphasis
  let enabled: Bool
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 4) {
      if changed {
        Circle().fill(Color.white.opacity(0.7)).frame(width: 4, height: 4)
      }
      if let symbol {
        Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
      }
      Text(text).font(.system(size: 12)).lineLimit(1)
      if let shortcut { KeyCap(text: shortcut).transition(.opacity) }
    }
    .foregroundStyle(.white.opacity(!enabled ? 0.25 : emphasis == .rest && !hovered ? 0.55 : 1))
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.white.opacity(emphasis == .open ? 0.14 : hovered && enabled ? 0.08 : 0))
        .strokeBorder(Color.white.opacity(emphasis == .focused ? 0.45 : 0), lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .fixedSize()
  }
}

/// A key drawn the way macOS menus show shortcuts.
struct KeyCap: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.white.opacity(0.7))
      .padding(.horizontal, 4)
      .frame(minWidth: 18, minHeight: 16)
      .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.12)))
  }
}

/// Both actions are keys first, so the footer shows the keys. Return lights up once there's a prompt.
private struct CalmFooter: View {
  @Bindable var lab: Lab
  let draft: StartDraft

  var body: some View {
    let canStart = !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    HStack(spacing: 14) {
      Spacer()
      Button {
        lab.discardCard()
      } label: {
        hint(key: "esc", label: "Discard", bright: false)
      }
      .buttonStyle(PressStyle())
      Button {
        lab.startThread()
      } label: {
        hint(key: "↩", label: "Start", bright: canStart)
      }
      .buttonStyle(PressStyle())
      .disabled(!canStart)
    }
    .padding(.horizontal, CalmCard.inset - Tokens.dropInset)
  }

  private func hint(key: String, label: String, bright: Bool) -> some View {
    HStack(spacing: 5) {
      Text(key)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(bright ? .black : .white.opacity(0.7))
        .padding(.horizontal, 5)
        .frame(minWidth: 20, minHeight: 18)
        .background(
          RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(bright ? 1 : 0.12)))
      Text(label)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(bright ? 0.9 : 0.5))
    }
    .contentShape(Rectangle())
  }
}
