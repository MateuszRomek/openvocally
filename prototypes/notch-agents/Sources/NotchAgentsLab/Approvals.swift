import SwiftUI

/// What the notch grows to show on its own when an agent asks for approval. It never takes
/// keyboard focus: its buttons take a click without activating the lab, and ⌥↩ and ⌥⎋ answer the
/// front card from any app.
struct ApprovalStack: View {
  @Bindable var lab: Lab

  var body: some View {
    let ids = lab.cardThreads
    Group {
      if lab.arrival == .peek, !lab.keyRevealed, let thread = lab.thread(lab.frontApproval),
        case .needsYou(let approval) = thread.state
      {
        Text("\(thread.title) wants to \(approval.verbPhrase)")
          .font(Tokens.label)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.top, 2)
          .padding(.bottom, -2)
      } else {
        switch lab.approvalQueue {
        case .oneAtATime:
          if let id = lab.frontApproval {
            card(id, front: true, pager: ids.count > 1 ? (ids.firstIndex(of: id) ?? 0, ids.count) : nil)
              .id(id)
              .transition(.blurReplace)
          }
        case .stacked:
          if let id = lab.frontApproval {
            VStack(spacing: 0) {
              card(id, front: true, pager: nil).id(id).transition(.blurReplace)
              Slivers(count: ids.count - 1)
              if ids.count > 1 {
                Text(ids.count == 2 ? "1 more waiting" : "\(ids.count - 1) more waiting")
                  .font(.system(size: 11))
                  .foregroundStyle(.tertiary)
                  .padding(.top, 6)
                  .contentTransition(.numericText())
              }
            }
          }
        case .list:
          ScrollView {
            VStack(spacing: 8) {
              ForEach(ids, id: \.self) { id in
                card(id, front: id == ids.first, pager: nil).transition(.blurReplace)
              }
            }
          }
          .scrollBounceBehavior(.basedOnSize)
          .frame(maxHeight: lab.conversationMaxHeight)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, Tokens.dropInset)
    .padding(.top, 4)
    .padding(.bottom, Tokens.dropInset)
  }

  @ViewBuilder private func card(_ id: Int, front: Bool, pager: (Int, Int)?) -> some View {
    if let thread = lab.thread(id), case .needsYou(let approval) = thread.state {
      ApprovalCard(
        lab: lab, thread: thread, approval: approval, focused: false, front: front, showsThread: true,
        pager: pager, onOpen: { lab.open(.expanded, on: lab.pointerScreen ?? 0, thread: id) })
    }
  }
}

/// The edges of the cards waiting behind the front one.
private struct Slivers: View {
  let count: Int

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<min(count, 2), id: \.self) { depth in
        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
          .fill(Color.white.opacity(0.06 - Double(depth) * 0.02))
          .frame(height: 5)
          .padding(.horizontal, CGFloat(depth + 1) * 10)
      }
    }
    .transition(.opacity)
  }
}

/// One approval: which thread asks, what exactly it will run or touch, the agent's reason, and
/// the answers. Used in the notch on its own and above the reply box in an open thread.
struct ApprovalCard: View {
  @Bindable var lab: Lab
  let thread: AgentThread
  let approval: Approval
  /// The open panel has keyboard focus, so ⌘ keys answer. Otherwise ⌥ keys answer from any app.
  let focused: Bool
  /// Only the front card answers to the keyboard, so its hints are the only ones shown.
  let front: Bool
  let showsThread: Bool
  var pager: (Int, Int)?
  /// A click on the card outside its buttons opens the thread.
  var onOpen: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsThread || pager != nil {
        HStack(spacing: 6) {
          if showsThread {
            Image(systemName: thread.provider.symbol).font(Tokens.glyph).foregroundStyle(.secondary)
            Text(thread.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Text(thread.project).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize()
          }
          Spacer(minLength: 8)
          if let (index, count) = pager { Pager(lab: lab, index: index, count: count) }
        }
      }
      Text(approval.title).font(Tokens.label).foregroundStyle(.white)
      CommandBlock(text: approval.command, length: lab.commandLength, selectable: focused)
      if approval.reason != nil || approval.detail != nil {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let reason = approval.reason {
            Text(reason).foregroundStyle(.secondary).lineLimit(2)
          }
          Spacer(minLength: 8)
          if let detail = approval.detail {
            Text(detail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
          }
        }
        .font(.system(size: 11))
      }
      footer
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .onTapGesture { onOpen?() }
  }

  @ViewBuilder private var footer: some View {
    if isListening {
      // Speaking while an approval waits denies it, so the card says so before you release.
      HStack(spacing: 8) {
        Bars(levels: lab.levels, live: true)
        Text("Release to deny and send this as the reason")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.8))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .frame(height: 24)
      .transition(.blurReplace)
    } else {
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        PillButton(title: "Deny", hint: hint(deny: true), prominent: false) { lab.deny(thread.id) }
          .keyboardShortcut(focused && front ? KeyboardShortcut(.delete, modifiers: .command) : nil)
        switch lab.allowPlacement {
        case .button:
          PillButton(title: "Allow for this thread", hint: nil, prominent: false) {
            lab.approve(thread.id, always: true)
          }
          allow
        case .menu:
          HStack(spacing: 2) {
            allow
            Menu {
              Button("Allow once") { lab.approve(thread.id) }
              Button("Allow for this thread") { lab.approve(thread.id, always: true) }
            } label: {
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .frame(width: 22, height: 24)
            .background(Capsule().fill(Color.white))
            .fixedSize()
          }
        }
      }
      .transition(.blurReplace)
    }
  }

  private var allow: some View {
    PillButton(title: "Allow", hint: hint(deny: false), prominent: true) { lab.approve(thread.id) }
      .keyboardShortcut(focused && front ? KeyboardShortcut(.return, modifiers: .command) : nil)
  }

  private func hint(deny: Bool) -> String? {
    guard front else { return nil }
    return switch (focused, deny) {
    case (true, true): "⌘⌫"
    case (true, false): "⌘↩"
    case (false, true): "⌥⎋"
    case (false, false): "⌥↩"
    }
  }

  private var isListening: Bool {
    if case .recording(let id) = lab.dictation, id == thread.id { return true }
    return false
  }
}

private struct Pager: View {
  @Bindable var lab: Lab
  let index: Int
  let count: Int

  var body: some View {
    HStack(spacing: 2) {
      step("chevron.left", -1).disabled(index == 0)
      Text("\(index + 1) of \(count)")
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
      step("chevron.right", 1).disabled(index == count - 1)
    }
  }

  private func step(_ symbol: String, _ by: Int) -> some View {
    Button {
      lab.animate(Tokens.swap) { lab.cardIndex = min(max(index + by, 0), count - 1) }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle())
  }
}

/// The exact command or path. In full it wraps and scrolls past ten lines; on one line it
/// truncates in the middle and expands on click.
private struct CommandBlock: View {
  let text: String
  let length: CommandLength
  let selectable: Bool
  @State private var expanded = false
  @State private var contentHeight: CGFloat = 0

  private var isLong: Bool { text.count > 56 || text.contains("\n") }
  private var oneLine: Bool { length == .oneLine && !expanded }
  private let maxHeight: CGFloat = 10 * 16

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      ScrollView {
        command
          .frame(maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(max(contentHeight, 15), maxHeight))
      if length == .oneLine, isLong {
        Button(expanded ? "Less" : "Show all") {
          withAnimation(Tokens.swap) { expanded.toggle() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize()
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
  }

  @ViewBuilder private var command: some View {
    let base = Text(oneLine ? text.replacingOccurrences(of: "\\\n", with: " ") : text)
      .font(.system(size: 11).monospaced())
      .foregroundStyle(.white.opacity(0.9))
      .lineLimit(oneLine ? 1 : nil)
      .truncationMode(.middle)
      .lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)
    if selectable { base.textSelection(.enabled) } else { base }
  }
}

struct PillButton: View {
  let title: String
  let hint: String?
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if let hint { Text(hint).opacity(0.55) }
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(prominent ? Color.black : .white)
      .padding(.horizontal, 10)
      .frame(height: 24)
      .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.12)))
      .contentShape(Capsule())
      .fixedSize()
    }
    .buttonStyle(PressStyle())
  }
}
