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
      switch approval.kind {
      case .questions(let questions):
        QuestionsBody(lab: lab, thread: thread.id, questions: questions, focused: focused, front: front)
      case .form(_, let fields):
        Text(approval.title).font(Tokens.label).foregroundStyle(.white)
        FormBody(lab: lab, thread: thread.id, fields: fields, focused: focused, onOpen: onOpen)
      case .browser, .app, .link:
        Text(approval.title).font(Tokens.label).foregroundStyle(.white)
        CommandBlock(text: approval.command, length: .full, selectable: focused)
      case .command, .edit, .fetch:
        Text(approval.title).font(Tokens.label).foregroundStyle(.white)
        CommandBlock(text: approval.command, length: lab.commandLength, selectable: focused)
      }
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
      // Speaking while an approval waits denies it, so the card says so before you release. A
      // question takes what you say as the answer instead.
      HStack(spacing: 8) {
        Bars(levels: lab.levels, live: true)
        Text(approval.isQuestion ? "Release to send this as your answer" : "Release to deny and send this as the reason")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.8))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .frame(height: 24)
      .transition(.blurReplace)
    } else {
      switch approval.kind {
      case .questions(let questions): questionFooter(questions)
      case .form: formFooter
      case .link: linkFooter
      case .browser, .app: lastingFooter
      case .command, .edit, .fetch: approvalFooter
      }
    }
  }

  @ViewBuilder private func questionFooter(_ questions: [Question]) -> some View {
    let current = lab.currentQuestion(thread.id)
    let multi = lab.questionLayout == .stepped ? questions[current].multiSelect : questions.contains(where: \.multiSelect) || questions.count > 1
    let last = lab.questionLayout == .all || current == questions.count - 1
    HStack(spacing: 6) {
      Text(focused ? "Or type your own answer below" : "Hold right ⌘ to answer in your words")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      Spacer(minLength: 8)
      PillButton(title: "Skip", hint: hint(deny: true), prominent: false) { lab.skip(thread.id) }
        .keyboardShortcut(focused && front ? KeyboardShortcut(.delete, modifiers: .command) : nil)
      if multi {
        let ready = last ? lab.canSubmit(thread.id) : !(lab.picks[thread.id]?[current] ?? []).isEmpty
        PillButton(title: last ? "Submit" : "Next", hint: ready ? hint(deny: false) : nil, prominent: ready) {
          last ? lab.submitQuestions(thread.id) : lab.advance(thread.id, from: current)
        }
        .disabled(!ready)
        .keyboardShortcut(focused && front && ready ? KeyboardShortcut(.return, modifiers: .command) : nil)
      }
    }
    .transition(.blurReplace)
  }

  @ViewBuilder private var formFooter: some View {
    let ready = lab.canSubmitForm(thread.id)
    HStack(spacing: 6) {
      Spacer(minLength: 0)
      PillButton(title: "Decline", hint: hint(deny: true), prominent: false) { lab.deny(thread.id) }
        .keyboardShortcut(focused && front ? KeyboardShortcut(.delete, modifiers: .command) : nil)
      PillButton(title: "Send", hint: ready ? hint(deny: false) : nil, prominent: ready) { lab.submitForm(thread.id) }
        .disabled(!ready)
        .keyboardShortcut(focused && front && ready ? KeyboardShortcut(.return, modifiers: .command) : nil)
    }
    .transition(.blurReplace)
  }

  @ViewBuilder private var linkFooter: some View {
    HStack(spacing: 6) {
      if lab.linksOpened.contains(thread.id) {
        ProgressView().controlSize(.mini).tint(.white)
        Text("Finish signing in in your browser")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        PillButton(title: "Cancel", hint: hint(deny: true), prominent: false) { lab.deny(thread.id) }
      } else {
        Spacer(minLength: 0)
        PillButton(title: "Decline", hint: hint(deny: true), prominent: false) { lab.deny(thread.id) }
          .keyboardShortcut(focused && front ? KeyboardShortcut(.delete, modifiers: .command) : nil)
        PillButton(title: "Open in browser", hint: hint(deny: false), prominent: true) { lab.openLink(thread.id) }
          .keyboardShortcut(focused && front ? KeyboardShortcut(.return, modifiers: .command) : nil)
      }
    }
    .transition(.blurReplace)
  }

  /// Browser and Computer Use: Allow carries the lab's chosen grant, the menu the others.
  @ViewBuilder private var lastingFooter: some View {
    let primary = lab.primaryGrant(approval)
    HStack(spacing: 6) {
      Spacer(minLength: 0)
      PillButton(title: "Deny", hint: hint(deny: true), prominent: false) { lab.deny(thread.id) }
        .keyboardShortcut(focused && front ? KeyboardShortcut(.delete, modifiers: .command) : nil)
      HStack(spacing: 2) {
        PillButton(title: primary == .once ? "Allow" : shortTitle(primary), hint: hint(deny: false), prominent: true) {
          lab.approve(thread.id, grant: primary)
        }
        .keyboardShortcut(focused && front ? KeyboardShortcut(.return, modifiers: .command) : nil)
        Menu {
          ForEach(approval.grants.filter { $0 != primary }, id: \.title) { grant in
            Button(grant.title) { lab.approve(thread.id, grant: grant) }
          }
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
    .transition(.blurReplace)
  }

  private func shortTitle(_ grant: Grant) -> String {
    switch grant {
    case .site: "Allow on this site"
    case .thread: "Allow for this thread"
    default: grant.title
    }
  }

  @ViewBuilder private var approvalFooter: some View {
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        PillButton(title: "Deny", hint: hint(deny: true), prominent: false) { lab.deny(thread.id) }
          .keyboardShortcut(focused && front ? KeyboardShortcut(.delete, modifiers: .command) : nil)
        switch lab.allowPlacement {
        case .button:
          PillButton(title: "Allow for this thread", hint: nil, prominent: false) {
            lab.approve(thread.id, grant: .thread)
          }
          allow
        case .menu:
          HStack(spacing: 2) {
            allow
            Menu {
              Button("Allow once") { lab.approve(thread.id) }
              Button("Allow for this thread") { lab.approve(thread.id, grant: .thread) }
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

// MARK: - Questions

/// An agent's question with its options. A click or ⌥ digit picks; speech answers in your words.
private struct QuestionsBody: View {
  @Bindable var lab: Lab
  let thread: Int
  let questions: [Question]
  let focused: Bool
  let front: Bool

  var body: some View {
    let current = lab.currentQuestion(thread)
    let shown = lab.questionLayout == .stepped ? [current] : Array(questions.indices)
    VStack(alignment: .leading, spacing: 12) {
      ForEach(shown, id: \.self) { index in
        question(index, keyed: front && (lab.questionLayout == .stepped || index == current))
          .id(index)
          .transition(.blurReplace)
      }
    }
  }

  @ViewBuilder private func question(_ index: Int, keyed: Bool) -> some View {
    let question = questions[index]
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text(question.header.uppercased())
          .font(.system(size: 10, weight: .semibold))
          .tracking(0.4)
          .foregroundStyle(.tertiary)
        if lab.questionLayout == .stepped, questions.count > 1 {
          Text("· \(index + 1) of \(questions.count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.tertiary)
            .contentTransition(.numericText())
          Spacer(minLength: 0)
          if index > 0 {
            Button("Back") { lab.stepQuestion(thread, by: -1) }
              .buttonStyle(.plain)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
          }
        }
      }
      Text(question.text)
        .font(Tokens.label)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
      if question.multiSelect {
        Text("Choose any").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
      switch lab.optionStyle {
      case .rows:
        VStack(spacing: 4) {
          ForEach(question.options.indices, id: \.self) { option in
            row(question, index, option, keyed: keyed)
          }
        }
      case .chips:
        HStack(spacing: 6) {
          ForEach(question.options.indices, id: \.self) { option in
            chip(question, index, option, keyed: keyed)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  private func row(_ question: Question, _ index: Int, _ option: Int, keyed: Bool) -> some View {
    let item = question.options[option]
    let picked = lab.isPicked(thread, question: index, option: option)
    return Button {
      lab.pick(thread, question: index, option: option)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        marker(question, picked: picked, number: option + 1, keyed: keyed)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
          if let detail = item.detail {
            Text(detail)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(picked ? 0.16 : 0.06)))
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(PressStyle())
    .keyboardShortcut(shortcut(option, keyed: keyed))
  }

  private func chip(_ question: Question, _ index: Int, _ option: Int, keyed: Bool) -> some View {
    let item = question.options[option]
    let picked = lab.isPicked(thread, question: index, option: option)
    return Button {
      lab.pick(thread, question: index, option: option)
    } label: {
      HStack(spacing: 4) {
        Text(item.label)
        if let hint = hint(option + 1, keyed: keyed) { Text(hint).opacity(0.55) }
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(picked ? Color.black : .white)
      .padding(.horizontal, 10)
      .frame(height: 24)
      .background(Capsule().fill(picked ? Color.white : Color.white.opacity(0.12)))
      .contentShape(Capsule())
      .fixedSize()
    }
    .buttonStyle(PressStyle())
    .help(item.detail ?? "")
    .keyboardShortcut(shortcut(option, keyed: keyed))
  }

  @ViewBuilder private func marker(_ question: Question, picked: Bool, number: Int, keyed: Bool) -> some View {
    if question.multiSelect {
      Image(systemName: picked ? "checkmark.square.fill" : "square")
        .font(.system(size: 11))
        .foregroundStyle(picked ? .white : .secondary)
        .frame(width: 26, alignment: .leading)
    } else {
      Text(hint(number, keyed: keyed) ?? "\(number)")
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(picked ? .white : .secondary)
        .frame(width: 26, alignment: .leading)
    }
  }

  private func hint(_ number: Int, keyed: Bool) -> String? {
    guard keyed else { return nil }
    if focused { return "⌘\(number)" }
    return lab.optionKeys == .option ? "⌥\(number)" : nil
  }

  private func shortcut(_ option: Int, keyed: Bool) -> KeyboardShortcut? {
    guard focused, keyed, option < 9 else { return nil }
    return KeyboardShortcut(KeyEquivalent(Character("\(option + 1)")), modifiers: .command)
  }
}

// MARK: - Forms

/// An MCP form. Choices and toggles take a click on the closed card; typing needs keyboard focus,
/// which the closed card never takes, so a text field opens the thread.
private struct FormBody: View {
  @Bindable var lab: Lab
  let thread: Int
  let fields: [FormField]
  let focused: Bool
  var onOpen: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !focused, lab.formPlacement == .panel {
        Text(fields.map(\.label).joined(separator: ", "))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        PillButton(title: "Fill in…", hint: nil, prominent: false) { onOpen?() }
      } else {
        ForEach(fields.indices, id: \.self) { index in
          field(index)
        }
      }
    }
  }

  @ViewBuilder private func field(_ index: Int) -> some View {
    let field = fields[index]
    let value = lab.formValues[thread]?[index] ?? ""
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(field.label + (field.required ? "" : " (optional)"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .leading)
      switch field.kind {
      case .choice(let options):
        HStack(spacing: 4) {
          ForEach(options, id: \.self) { option in
            Button {
              lab.setField(thread, field: index, value: option)
            } label: {
              Text(option)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(value == option ? Color.black : .white)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(value == option ? Color.white : Color.white.opacity(0.12)))
                .fixedSize()
            }
            .buttonStyle(PressStyle())
          }
        }
      case .toggle:
        Button {
          lab.setField(thread, field: index, value: value == "on" ? "" : "on")
        } label: {
          Image(systemName: value == "on" ? "checkmark.square.fill" : "square")
            .font(.system(size: 12))
            .foregroundStyle(value == "on" ? .white : .secondary)
        }
        .buttonStyle(PressStyle())
      case .text(let placeholder):
        if focused {
          TextField(
            text: Binding(get: { value }, set: { lab.setField(thread, field: index, value: $0) }),
            prompt: Text(placeholder).foregroundStyle(.white.opacity(0.4))
          ) { Text(field.label) }
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .frame(height: 24)
          .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
        } else {
          // The closed card can't take typing, so the field is a button into the thread.
          Button { onOpen?() } label: {
            HStack {
              Text(value.isEmpty ? placeholder : value)
                .font(.system(size: 12))
                .foregroundStyle(value.isEmpty ? .white.opacity(0.4) : .white)
                .lineLimit(1)
              Spacer(minLength: 4)
              Text("Click to type").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}
