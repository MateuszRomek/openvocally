import SwiftUI

/// The open level below the closed row. Drill-in shows the list, then one thread in full; the
/// preview layout keeps the list and shows the selected thread's conversation below it.
struct ThreadPanel: View {
  @Bindable var lab: Lab

  var body: some View {
    ZStack(alignment: .top) {
      if lab.panelLayout == .drillIn, let thread = lab.thread(lab.openThread) {
        ThreadView(lab: lab, thread: thread)
          .transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
      } else {
        ThreadList(lab: lab)
          .transition(.asymmetric(insertion: .push(from: .leading), removal: .push(from: .trailing)))
      }
    }
    .padding(.horizontal, Tokens.dropInset)
    .padding(.top, 4)
    .padding(.bottom, Tokens.dropInset)
    .clipped()
    .background {
      Button("Back or close") { lab.escape() }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
    }
  }
}

// MARK: - List

private struct ThreadList: View {
  @Bindable var lab: Lab

  private var ordered: [AgentThread] { lab.threads.sorted { $0.updated > $1.updated } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(ordered) { thread in
            ThreadRow(
              thread: thread, selected: thread.id == lab.selectedThread, indicator: lab.working,
              showsPreview: lab.panelLayout == .drillIn
            )
            .onTapGesture { tap(thread.id) }
          }
          Button {
            lab.newThread()
          } label: {
            Label("New thread", systemImage: "plus")
              .font(Tokens.label)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
          }
          .buttonStyle(PressStyle())
          .keyboardShortcut("n", modifiers: .command)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: lab.panelLayout == .drillIn ? 380 : 196)
      .fixedSize(horizontal: false, vertical: true)

      if lab.panelLayout == .preview, let thread = lab.thread(lab.selectedThread) {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        Conversation(thread: thread, maxHeight: 200, lastReplyOnly: true)
        ThreadFooter(lab: lab, thread: thread)
      }
    }
    .background {
      // Keyboard path through the list: arrows move, Return opens the thread.
      if lab.panelLayout == .drillIn {
        Group {
          Button("Up") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
          Button("Down") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
          Button("Open") { if let id = lab.selectedThread { lab.show(thread: id) } }
            .keyboardShortcut(.return, modifiers: [])
        }
        .opacity(0)
      }
    }
  }

  private func tap(_ id: Int) {
    if lab.panelLayout == .drillIn {
      lab.show(thread: id)
    } else {
      withAnimation(lab.animation(Tokens.swap)) { lab.selectedThread = id }
    }
  }

  private func move(_ step: Int) {
    let ids = ordered.map(\.id)
    guard !ids.isEmpty else { return }
    let index = lab.selectedThread.flatMap { ids.firstIndex(of: $0) } ?? 0
    lab.selectedThread = ids[min(max(index + step, 0), ids.count - 1)]
  }
}

private struct ThreadRow: View {
  let thread: AgentThread
  let selected: Bool
  let indicator: WorkingIndicator
  let showsPreview: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: thread.provider.symbol)
        .font(Tokens.glyph)
        .foregroundStyle(.secondary)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(thread.title).font(Tokens.label).foregroundStyle(.white).lineLimit(1)
        Text(showsPreview && !thread.lastLine.isEmpty ? thread.lastLine : "\(thread.project) · \(thread.provider.rawValue)")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if thread.state == .idle {
        Text(thread.updated, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .fixedSize()
      } else {
        StateMark(state: thread.state, indicator: indicator).fixedSize()
      }
      if showsPreview {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(selected ? 0.1 : 0))
    }
    .contentShape(Rectangle())
  }
}

// MARK: - One thread

private struct ThreadView: View {
  @Bindable var lab: Lab
  let thread: AgentThread
  @State private var handedOff = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Button {
          lab.back()
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to threads (Esc)")
        VStack(alignment: .leading, spacing: 1) {
          Text(thread.title).font(Tokens.label).foregroundStyle(.white).lineLimit(1)
          Text(handedOff ? "Opens in the Agents section of the main window" : "\(thread.project) · \(thread.provider.rawValue)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.opacity)
        }
        Spacer(minLength: 8)
        if thread.state != .idle {
          StateMark(state: thread.state, indicator: lab.working).fixedSize()
        }
        Button {
          withAnimation(lab.animation(Tokens.swap)) { handedOff = true }
          Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(lab.animation(Tokens.swap)) { handedOff = false }
          }
        } label: {
          Image(systemName: "macwindow")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut("o", modifiers: .command)
        .help("Open in the Agents section (⌘O)")
      }
      Conversation(thread: thread, maxHeight: lab.conversationMaxHeight, lastReplyOnly: false)
      ThreadFooter(lab: lab, thread: thread)
    }
  }
}

/// The approval card, when there is one, and the reply box.
private struct ThreadFooter: View {
  @Bindable var lab: Lab
  let thread: AgentThread
  @FocusState private var replyFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .needsYou(let approval) = thread.state {
        ApprovalCard(
          lab: lab, thread: thread, approval: approval, focused: !lab.passive, front: true, showsThread: false)
          .transition(.blurReplace)
      }
      ReplyBox(lab: lab, thread: thread, focused: $replyFocused)
    }
    .onAppear { replyFocused = lab.panelLayout == .drillIn }
  }
}

// MARK: - Conversation

/// The thread's messages, newest at the bottom. Tool steps fold into one line per run of steps.
/// Text is selectable, so a quick lookup can end in a copy.
private struct Conversation: View {
  let thread: AgentThread
  let maxHeight: CGFloat
  /// The preview layout shows only the newest exchange.
  let lastReplyOnly: Bool
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if blocks.isEmpty {
          Text("No messages yet. Type or hold right ⌘ to speak.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
        }
        ForEach(blocks) { block in
          switch block.kind {
          case .user(let text): UserBubble(text: text)
          case .agent(let text): AgentText(text: text)
          case .tools(let steps): ToolSteps(steps: steps)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .mask {
      VStack(spacing: 0) {
        Color.black
        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
          .frame(height: contentHeight > maxHeight ? 14 : 0)
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(max(contentHeight, 20), maxHeight))
  }

  private struct Block: Identifiable {
    enum Kind {
      case user(String)
      case agent(String)
      case tools([String])
    }
    let id: Int
    let kind: Kind
  }

  private var blocks: [Block] {
    var messages = thread.messages
    if lastReplyOnly, let lastUser = messages.lastIndex(where: { $0.role == .user }) {
      messages = Array(messages[lastUser...])
    }
    var result: [Block] = []
    var tools: [String] = []
    var toolsID = 0
    func flush() {
      if !tools.isEmpty { result.append(Block(id: toolsID, kind: .tools(tools))) }
      tools = []
    }
    for message in messages {
      switch message.role {
      case .tool:
        if tools.isEmpty { toolsID = message.id }
        tools.append(message.text)
      case .user:
        flush()
        result.append(Block(id: message.id, kind: .user(message.text)))
      case .agent:
        flush()
        result.append(Block(id: message.id, kind: .agent(message.text)))
      }
    }
    flush()
    return result
  }
}

private struct UserBubble: View {
  let text: String

  var body: some View {
    HStack {
      Spacer(minLength: 60)
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12)))
    }
  }
}

private struct AgentText: View {
  let text: String

  var body: some View {
    Text(attributed)
      .font(.system(size: 12))
      .foregroundStyle(.white.opacity(0.92))
      .lineSpacing(3)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var attributed: AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

private struct ToolSteps: View {
  let steps: [String]
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(Tokens.swap) { expanded.toggle() }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
          Text(summary).lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        ForEach(steps.indices, id: \.self) { index in
          Text(steps[index])
            .font(.system(size: 11).monospaced())
            .foregroundStyle(.secondary)
            .padding(.leading, 13)
        }
      }
    }
  }

  private var summary: String {
    steps.count == 1 ? steps[0] : "\(steps.count) steps · \(steps.last ?? "")"
  }
}

// MARK: - Approval and reply

private struct ReplyBox: View {
  @Bindable var lab: Lab
  let thread: AgentThread
  var focused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      if isListening {
        Bars(levels: lab.levels, live: true)
        Text("Listening").font(Tokens.label).foregroundStyle(.white.opacity(0.75))
        Spacer()
      } else {
        TextField(
          text: $lab.reply,
          prompt: Text(placeholder).foregroundStyle(.white.opacity(0.5))
        ) {
          Text("Reply")
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .focused(focused)
        .onSubmit { lab.sendReply() }
        if lab.reply.isEmpty {
          Text("Hold right ⌘ to speak")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize()
            .transition(.opacity)
        } else {
          Button {
            lab.sendReply()
          } label: {
            Image(systemName: "arrow.up")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(.black)
              .frame(width: 22, height: 22)
              .background(Circle().fill(Color.white))
          }
          .buttonStyle(PressStyle())
          .help("Send (Return)")
          .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
      }
    }
    .padding(.leading, 12)
    .padding(.trailing, 7)
    .frame(height: 36)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.12))
        .strokeBorder(Color.white.opacity(focused.wrappedValue ? 0.32 : 0.16), lineWidth: 1)
    }
    .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: lab.reply.isEmpty)
    .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: focused.wrappedValue)
  }

  private var isListening: Bool {
    if case .recording(let id) = lab.dictation, id == thread.id { return true }
    return false
  }

  /// Sending while an approval waits denies it and passes the text on as the reason.
  private var placeholder: String {
    if case .needsYou(let approval) = thread.state {
      return approval.isQuestion ? "Answer in your own words" : "Deny and say why"
    }
    return "Reply to \(thread.title)"
  }
}

/// Shrinks on press, the way the app's buttons do.
struct PressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: configuration.isPressed)
  }
}
