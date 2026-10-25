import AppKit
import SwiftUI

// MARK: - Settings a thread starts with

struct Project: Equatable {
  let name: String
  let isGit: Bool
  let branches: [String]
  /// The checked-out branch, which a worktree starts from by default.
  let current: String
  /// The per-project setup command a new worktree runs before the agent starts.
  let setup: String?
}

/// Everything the card prefills from the last thread you started. Mode, model and effort belong
/// to the provider; the lists are placeholders until Provider settings and switching decides them.
struct ThreadSettings: Equatable {
  var project: String
  var provider: Provider
  var mode: String
  var model: String
  var effort: String
  var worktree: Bool
  var base: String
}

extension Provider {
  var modes: [String] {
    switch self {
    case .claude: ["Ask before edits", "Accept edits", "Plan", "Auto"]
    case .codex: ["Read only", "Auto", "Full access"]
    }
  }

  var models: [String] {
    switch self {
    case .claude: ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1"]
    case .codex: ["gpt-5.5-codex", "gpt-5.5", "gpt-5.5-mini"]
    }
  }

  var efforts: [String] {
    switch self {
    case .claude: ["Low", "Medium", "High", "Extra high", "Max"]
    case .codex: ["Minimal", "Low", "Medium", "High"]
    }
  }
}

/// The card's controls, in the order they sit and the order ⌘1… reaches them. The first row is
/// where the thread runs, the second who runs it. Numbers stay fixed when the base branch hides.
enum CardControl: Int, CaseIterable, Identifiable {
  case project, worktree, base, provider, mode, model, effort

  static let place: [Self] = [.project, .worktree, .base]
  static let agent: [Self] = [.provider, .mode, .model, .effort]
  var id: Self { self }

  var title: String {
    switch self {
    case .project: "Project"
    case .provider: "Provider"
    case .mode: "Mode"
    case .model: "Model"
    case .effort: "Reasoning"
    case .worktree: "Worktree"
    case .base: "Base branch"
    }
  }

  /// The letter after ⌘⇧ in the chords variant, after T3 Code and OpenCode where they have one.
  var chordLetter: String {
    switch self {
    case .project: "O"
    case .provider: "P"
    case .mode: "A"
    case .model: "M"
    case .effort: "E"
    case .worktree: "X"
    case .base: "G"
    }
  }

  var symbol: String {
    switch self {
    case .project: "folder"
    case .provider: "asterisk"
    case .mode: "hand.raised"
    case .model: "cpu"
    case .effort: "gauge.with.dots.needle.50percent"
    case .worktree: "arrow.triangle.branch"
    case .base: "arrow.turn.down.right"
    }
  }
}

/// A new thread that hasn't started. It lives until Enter starts it or Esc throws it away;
/// clicking into another app only parks it in the notch.
struct StartDraft: Equatable {
  var prompt = ""
  var settings: ThreadSettings
  /// Nil follows the prompt's first words.
  var branchOverride: String?
  /// Set while the worktree launch checklist runs: how many steps are done.
  var launchStep: Int?

  var branch: String { branchOverride ?? Self.branch(for: prompt) }

  static func branch(for prompt: String) -> String {
    let words = prompt.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .prefix(4)
    return "feature/" + (words.isEmpty ? "new-thread" : words.joined(separator: "-"))
  }
}

// MARK: - Lab options

enum PickerKeys: String, CaseIterable, Identifiable {
  case numbered = "⌘1… opens each picker"
  case tab = "Tab through the chips, ← → change"
  /// T3 Code's keys: ⌘⇧ and a letter opens a picker, ⇧Tab cycles the mode.
  case chords = "⌘⇧ letters, ⇧Tab cycles mode"
  var id: Self { self }
}

enum PromptStyle: String, CaseIterable, Identifiable {
  case field = "Editable, caret at the end"
  case text = "Text, click or type to edit"
  var id: Self { self }
}

enum DraftMark: String, CaseIterable, Identifiable {
  case word = "Pencil and Draft"
  case glyph = "Pencil only"
  case line = "Draft and its first words"
  var id: Self { self }
}

enum NewThreadKey: String, CaseIterable, Identifiable {
  case card = "Opens an empty card"
  case target = "Only targets a new thread"
  var id: Self { self }
}

enum Respeak: String, CaseIterable, Identifiable {
  case replace = "Replaces the prompt"
  case append = "Adds to the prompt"
  case ignore = "Is ignored"
  var id: Self { self }
}

enum DraftOnNew: String, CaseIterable, Identifiable {
  case reopen = "Reopens the draft"
  case fresh = "Drops it for an empty card"
  var id: Self { self }
}

// MARK: - Behavior

extension Lab {
  /// The agent target that means "start a new thread" rather than an existing one.
  static let newThreadTarget = -1

  static let projects = [
    Project(
      name: "openvocally", isGit: true, branches: ["main", "notch-lab", "release/1.0.4"], current: "main",
      setup: "make generate"),
    Project(name: "site", isGit: true, branches: ["main", "redesign"], current: "redesign", setup: nil),
    Project(name: "notes", isGit: false, branches: [], current: "", setup: nil),
  ]

  static let firstSettings = ThreadSettings(
    project: "openvocally", provider: .claude, mode: "Accept edits", model: "Opus 5.5", effort: "High",
    worktree: false, base: "main")

  static let projectSettings: [String: ThreadSettings] = [
    "openvocally": firstSettings,
    "site": ThreadSettings(
      project: "site", provider: .codex, mode: "Auto", model: "gpt-5.5-codex", effort: "Medium", worktree: true,
      base: "redesign"),
    "notes": ThreadSettings(
      project: "notes", provider: .claude, mode: "Plan", model: "Sonnet 5.5", effort: "Medium", worktree: false,
      base: ""),
  ]

  /// What the lab pretends you said to start a thread, and what you said the second time.
  static let spokenPrompt = "Add a Reset button to the lab's control window that clears every draft."
  static let respokenPrompt = "And put the notch back to idle after the reset."
  /// What plain dictation pastes into the card's prompt.
  static let dictatedWords = "Keep the button below Sequences."

  static func project(_ name: String) -> Project {
    projects.first { $0.name == name } ?? projects[0]
  }

  var visibleControls: [CardControl] {
    guard let settings = draft?.settings else { return [] }
    return CardControl.allCases.filter { $0 != .base || settings.worktree }
  }

  /// Where the card's settings came from, for the footer.
  var settingsOrigin: String {
    guard let settings = draft?.settings else { return "" }
    if settings == lastSettings { return "As your last thread" }
    if settings == lastByProject[settings.project] { return "As your last thread in \(settings.project)" }
    return "Changed for this thread"
  }

  // MARK: Opening and closing

  /// ⌥T from any app.
  func newThreadKey() {
    guard openLevel != .start else { return }
    if newThreadKeyBehavior == .target {
      animate(Tokens.instant) { newThreadArmed.toggle() }
      return
    }
    if draftOnNew == .fresh { draft = nil }
    openCard(fromKeyboard: true)
  }

  func openCard(fromKeyboard: Bool, on screen: ScreenID? = nil) {
    if draft == nil { draft = StartDraft(settings: lastSettings) }
    openControl = nil
    focusedControl = nil
    filter = ""
    editingPrompt = false
    cardKeys = 0
    newThreadArmed = false
    let main = NSScreen.main?.screenID ?? 0
    open(.start, on: screen ?? (scope == .main ? main : pointerScreen ?? main), fromKeyboard: fromKeyboard)
  }

  /// Clicking into another app. A card with nothing in it isn't worth keeping.
  func parkDraft() {
    guard openLevel == .start else { return }
    if draft?.prompt.isEmpty ?? true { draft = nil }
    closeAll()
  }

  func discardCard() {
    let hadPrompt = !(draft?.prompt.isEmpty ?? true)
    closeAll(fromKeyboard: true)
    draft = nil
    if hadPrompt { flash(.discarded) }
  }

  /// Speech whose target is a new thread: it fills the card, which opens if it isn't already.
  func receiveSpeech() {
    if draft == nil { draft = StartDraft(settings: lastSettings) }
    if draft?.prompt.isEmpty ?? true {
      draft?.prompt = Lab.spokenPrompt
    } else {
      switch respeak {
      case .replace: draft?.prompt = Lab.respokenPrompt
      case .append: draft?.prompt += " " + Lab.respokenPrompt
      case .ignore: break
      }
    }
    if openLevel != .start { openCard(fromKeyboard: false) }
  }

  /// Plain dictation pastes at the card's caret, as it would into any focused field.
  func pasteIntoCard() {
    guard draft != nil else { return }
    let prompt = draft?.prompt ?? ""
    draft?.prompt = prompt.isEmpty ? Lab.dictatedWords : prompt + " " + Lab.dictatedWords
  }

  // MARK: Starting

  func startThread() {
    guard let start = draft, start.launchStep == nil,
      !start.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    remember(start.settings)
    guard start.settings.worktree, Lab.project(start.settings.project).isGit else {
      finish(start)
      return
    }
    // A worktree thread shows its checklist before the first turn.
    animate(Tokens.swap) { draft?.launchStep = 0 }
    Task {
      for step in 1...launchSteps(start).count {
        try? await pause(0.7)
        animate(Tokens.swap) { draft?.launchStep = step }
      }
      try? await pause(0.35)
      finish(start)
    }
  }

  func launchSteps(_ start: StartDraft) -> [String] {
    let settings = start.settings
    var steps = ["Check out \(start.branch) from \(settings.base)"]
    if let setup = Lab.project(settings.project).setup { steps.append("Run \(setup)") }
    steps.append("Start \(settings.provider.rawValue)")
    return steps
  }

  private func finish(_ start: StartDraft) {
    let id = (threads.map(\.id).max() ?? 0) + 1
    let words = start.prompt.split(separator: " ").prefix(6).joined(separator: " ")
    closeAll()
    draft = nil
    swap {
      threads.append(
        AgentThread(
          id: id, title: words, project: start.settings.project, provider: start.settings.provider,
          state: .working("Thinking"), messages: [], updated: .now))
      selectedThread = id
    }
    Lab.start(self, id, prompt: start.prompt)
    flash(.started(thread: id))
  }

  private static func start(_ lab: Lab, _ id: Int, prompt: String) {
    lab.start(
      id,
      Turn(
        prompt: prompt, steps: ["Read LabApp.swift", "Edited LabApp.swift"], approval: nil,
        reply: "Added **Reset** under Sequences. It clears every draft and closes the notch.",
        end: .done("Answered")))
  }

  private func remember(_ settings: ThreadSettings) {
    lastSettings = settings
    lastByProject[settings.project] = settings
    lastByProvider[settings.provider] = settings
  }

  func flash(_ state: Dictation) {
    swap { dictation = state }
    Task {
      try? await pause(1.1)
      guard dictation == state else { return }
      animate(Tokens.hide) { dictation = .off }
    }
  }

  // MARK: Controls

  /// The value as the option lists spell it.
  func raw(_ control: CardControl, _ settings: ThreadSettings) -> String {
    control == .base ? settings.base : value(control, settings)
  }

  func value(_ control: CardControl, _ settings: ThreadSettings) -> String {
    switch control {
    case .project: settings.project
    case .provider: settings.provider.rawValue
    case .mode: settings.mode
    case .model: settings.model
    case .effort: settings.effort
    case .worktree: settings.worktree ? "Worktree" : "No worktree"
    case .base: "from \(settings.base)"
    }
  }

  func options(_ control: CardControl) -> [String] {
    guard let settings = draft?.settings else { return [] }
    return switch control {
    case .project: Lab.projects.map(\.name)
    case .provider: Provider.allCases.map(\.rawValue)
    case .mode: settings.provider.modes
    case .model: settings.provider.models
    case .effort: settings.provider.efforts
    case .worktree: []
    case .base: Lab.project(settings.project).branches
    }
  }

  var filteredOptions: [String] {
    guard let openControl else { return [] }
    let all = options(openControl)
    return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
  }

  func isEnabled(_ control: CardControl) -> Bool {
    control != .worktree || Lab.project(draft?.settings.project ?? "").isGit
  }

  /// Choosing a project brings back that project's last settings; choosing a provider brings back
  /// its last mode, model and effort.
  func choose(_ control: CardControl, _ choice: String) {
    guard var settings = draft?.settings else { return }
    switch control {
    case .project:
      let project = Lab.project(choice)
      if let last = lastByProject[choice] {
        settings = last
      } else {
        settings.project = choice
        settings.base = project.current
      }
      if !project.isGit { settings.worktree = false }
    case .provider:
      guard let provider = Provider(rawValue: choice), provider != settings.provider else { return }
      let last = lastByProvider[provider]
      settings.provider = provider
      settings.mode = last?.mode ?? provider.modes[0]
      settings.model = last?.model ?? provider.models[0]
      settings.effort = last?.effort ?? provider.efforts[provider.efforts.count / 2]
    case .mode: settings.mode = choice
    case .model: settings.model = choice
    case .effort: settings.effort = choice
    case .base: settings.base = choice
    case .worktree: return
    }
    draft?.settings = settings
  }

  func toggleWorktree() {
    guard isEnabled(.worktree) else { return }
    draft?.settings.worktree.toggle()
    if focusedControl == .base, draft?.settings.worktree == false { focusedControl = .worktree }
  }

  func openList(_ control: CardControl) {
    guard control != .worktree else {
      toggleWorktree()
      return
    }
    openControl = control
    filter = ""
    let current = draft.map { raw(control, $0.settings) } ?? ""
    highlight = options(control).firstIndex(of: current) ?? 0
  }

  func closeList() {
    openControl = nil
    filter = ""
  }

  func tap(_ control: CardControl) {
    if openControl == control { closeList() } else { openList(control) }
  }

  /// ← → on a focused chip: the next value in place, with no list.
  private func cycle(_ control: CardControl, by step: Int) {
    guard control != .worktree else {
      toggleWorktree()
      return
    }
    let all = options(control)
    guard !all.isEmpty, let settings = draft?.settings else { return }
    let index = all.firstIndex(of: raw(control, settings)) ?? 0
    choose(control, all[(index + step + all.count) % all.count])
  }

  private func moveFocus(_ step: Int) {
    let stops: [CardControl?] = [nil] + visibleControls.filter(isEnabled).map(Optional.some)
    let index = stops.firstIndex(of: focusedControl) ?? 0
    focusedControl = stops[(index + step + stops.count) % stops.count]
    closeList()
  }

  // MARK: Keys

  /// Every key the focused card receives. The prompt field gets only what's left over.
  func cardKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    if !event.isARepeat { cardKeys += 1 }
    guard draft?.launchStep == nil else { return true }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    let typed = event.characters ?? ""
    let printable =
      (flags.isEmpty || flags == .shift) && !typed.isEmpty
      && typed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }

    switch event.keyCode {
    case 53:  // Esc steps back one level, then discards.
      if openControl != nil {
        closeList()
      } else if focusedControl != nil {
        focusedControl = nil
      } else {
        discardCard()
      }
      return true
    case 36, 76:  // Return
      if flags == .shift || flags == .option {
        draft?.prompt += "\n"
        editingPrompt = true
      } else if let openControl {
        let list = filteredOptions
        if list.indices.contains(highlight) { choose(openControl, list[highlight]) }
        closeList()
      } else {
        startThread()
      }
      return true
    case 48 where pickerKeys == .tab:
      moveFocus(flags.contains(.shift) ? -1 : 1)
      return true
    default:
      break
    }

    if pickerKeys == .numbered, flags == .command,
      let number = Int(event.charactersIgnoringModifiers ?? ""), number >= 1
    {
      if let control = CardControl(rawValue: number - 1), visibleControls.contains(control), isEnabled(control) {
        tap(control)
      }
      return true
    }

    if pickerKeys == .chords, flags == [.command, .shift],
      let control = CardControl.allCases.first(where: {
        $0.chordLetter == (event.charactersIgnoringModifiers ?? "").uppercased()
      })
    {
      if visibleControls.contains(control) { tap(control) }
      return true
    }

    // ⇧Tab cycles the mode, as it does in Claude Code, T3 Code and OpenCode.
    if pickerKeys != .tab, event.keyCode == 48, flags == .shift {
      closeList()
      cycle(.mode, by: 1)
      return true
    }

    if let openControl {
      switch event.keyCode {
      case 126: highlight = max(highlight - 1, 0)
      case 125: highlight = min(highlight + 1, max(filteredOptions.count - 1, 0))
      case 123, 124:
        // Sideways moves to the neighbouring picker's list.
        let lists = visibleControls.filter { $0 != .worktree }
        let index = lists.firstIndex(of: openControl) ?? 0
        openList(lists[(index + (event.keyCode == 124 ? 1 : -1) + lists.count) % lists.count])
        if pickerKeys == .tab { focusedControl = self.openControl }
      case 51:
        if !filter.isEmpty { filter.removeLast() }
        highlight = 0
      default:
        guard printable else { return flags.isEmpty }
        filter += typed
        highlight = 0
      }
      return true
    }

    if pickerKeys == .tab, let focusedControl {
      switch event.keyCode {
      case 123: cycle(focusedControl, by: -1)
      case 124: cycle(focusedControl, by: 1)
      case 49, 125: openList(focusedControl)
      default:
        guard printable, focusedControl != .worktree else { return flags.isEmpty }
        openList(focusedControl)
        filter = typed
      }
      return true
    }

    // Typing into a prompt shown as text starts editing it.
    if promptStyle == .text, !editingPrompt {
      guard printable else { return false }
      draft?.prompt += (draft?.prompt.isEmpty ?? true) ? typed : " " + typed
      editingPrompt = true
      return true
    }
    return false
  }
}

// MARK: - Views

/// The card the notch grows into for a new thread. Nothing starts until Enter.
struct StartCard: View {
  @Bindable var lab: Lab

  var body: some View {
    if let draft = lab.draft {
      VStack(alignment: .leading, spacing: 10) {
        if let step = draft.launchStep {
          LaunchChecklist(steps: lab.launchSteps(draft), done: step)
        } else {
          PromptBox(lab: lab, draft: draft)
          ControlRows(lab: lab, draft: draft)
          if lab.openControl != nil {
            OptionList(lab: lab, settings: draft.settings)
          }
          CardFooter(lab: lab, canStart: !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(.horizontal, Tokens.dropInset)
      .padding(.top, 4)
      .padding(.bottom, Tokens.dropInset)
    }
  }
}

private struct PromptBox: View {
  @Bindable var lab: Lab
  let draft: StartDraft
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if isListening {
        HStack(spacing: 8) {
          Bars(levels: lab.levels, live: true)
          Text(draft.prompt.isEmpty ? "Listening" : listeningNote)
            .font(Tokens.label)
            .foregroundStyle(.white.opacity(0.75))
          Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
      } else if lab.promptStyle == .field || lab.editingPrompt {
        TextField(text: prompt, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.45)), axis: .vertical) {
          Text("Prompt")
        }
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .focused($focused)
      } else {
        Text(draft.prompt.isEmpty ? placeholder : draft.prompt)
          .foregroundStyle(draft.prompt.isEmpty ? .white.opacity(0.45) : .white)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { lab.editingPrompt = true }
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(.white)
    .lineSpacing(2)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.1))
        .strokeBorder(Color.white.opacity(focused ? 0.3 : 0.14), lineWidth: 1)
    }
    .onAppear { focused = wantsFocus }
    .onChange(of: wantsFocus) { _, wants in focused = wants }
  }

  private var wantsFocus: Bool {
    !lab.passive && lab.focusedControl == nil && (lab.promptStyle == .field || lab.editingPrompt)
  }

  private var prompt: Binding<String> {
    Binding(get: { lab.draft?.prompt ?? "" }, set: { lab.draft?.prompt = $0 })
  }

  private var placeholder: String {
    lab.newThreadKeyBehavior == .card ? "Type, or hold right ⌘ and speak" : "Hold right ⌘ and speak"
  }

  private var listeningNote: String {
    switch lab.respeak {
    case .replace: "Listening. This replaces the prompt."
    case .append: "Listening. This adds to the prompt."
    case .ignore: "Listening. The prompt stays as it is."
    }
  }

  private var isListening: Bool {
    if case .recording(let target) = lab.dictation, target == Lab.newThreadTarget { return true }
    return false
  }
}

private struct ControlRows: View {
  @Bindable var lab: Lab
  let draft: StartDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        chips(CardControl.place)
        if draft.settings.worktree {
          TextField("Branch", text: branch)
            .textFieldStyle(.plain)
            .font(.system(size: 11).monospaced())
            .foregroundStyle(.secondary)
            .padding(.leading, 3)
        }
      }
      HStack(spacing: 5) { chips(CardControl.agent) }
    }
  }

  private func chips(_ controls: [CardControl]) -> some View {
    ForEach(controls.filter(lab.visibleControls.contains)) { control in
      Chip(
        control: control,
        text: control == .worktree && !lab.isEnabled(control) ? "Not a git folder" : lab.value(control, draft.settings),
        symbol: control == .provider ? draft.settings.provider.symbol : control.symbol,
        shortcut: shortcut(control),
        isOpen: lab.openControl == control,
        isFocused: lab.focusedControl == control,
        isEnabled: lab.isEnabled(control),
        isToggle: control == .worktree,
        isOn: control == .worktree && draft.settings.worktree
      )
      .fixedSize()
      .onTapGesture { if lab.isEnabled(control) { lab.tap(control) } }
    }
  }

  private var branch: Binding<String> {
    Binding(get: { lab.draft?.branch ?? "" }, set: { lab.draft?.branchOverride = $0 })
  }

  private func shortcut(_ control: CardControl) -> String? {
    switch lab.pickerKeys {
    case .numbered: "⌘\(control.rawValue + 1)"
    case .tab: nil
    case .chords: "⇧⌘\(control.chordLetter)"
    }
  }
}

private struct Chip: View {
  let control: CardControl
  let text: String
  let symbol: String
  let shortcut: String?
  let isOpen: Bool
  let isFocused: Bool
  let isEnabled: Bool
  let isToggle: Bool
  let isOn: Bool

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
      Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
      if let shortcut {
        Text(shortcut).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.35))
      }
    }
    .foregroundStyle(.white.opacity(isEnabled ? (isToggle && !isOn ? 0.55 : 0.92) : 0.3))
    .padding(.horizontal, 8)
    .frame(height: 22)
    .background {
      Capsule()
        .fill(Color.white.opacity(isOpen ? 0.2 : isToggle && isOn ? 0.16 : 0.08))
        .strokeBorder(Color.white.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
    }
    .contentShape(Capsule())
    .help(control.title)
  }
}

/// The open picker, inside the card rather than in a popover, so it never takes focus from it.
private struct OptionList: View {
  @Bindable var lab: Lab
  let settings: ThreadSettings

  var body: some View {
    let options = lab.filteredOptions
    let current = lab.openControl.map { lab.raw($0, settings) }
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(lab.openControl?.title ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        Spacer()
        Text(lab.filter.isEmpty ? "Type to filter" : lab.filter)
          .font(.system(size: 11))
          .foregroundStyle(lab.filter.isEmpty ? .tertiary : .primary)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 2)
      if options.isEmpty {
        Text("No match").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 8)
      }
      ForEach(Array(options.enumerated()), id: \.element) { index, option in
        HStack(spacing: 8) {
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .opacity(option == current ? 1 : 0)
          Text(option).font(.system(size: 12))
          Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(index == lab.highlight ? 0.12 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if let control = lab.openControl { lab.choose(control, option) }
          lab.closeList()
        }
      }
    }
    .padding(4)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
  }
}

private struct CardFooter: View {
  @Bindable var lab: Lab
  let canStart: Bool

  var body: some View {
    HStack(spacing: 12) {
      Text(lab.settingsOrigin).font(.system(size: 11)).foregroundStyle(.tertiary)
      Spacer()
      Button("Discard") { lab.discardCard() }
        .buttonStyle(PressStyle())
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .help("Discard (Esc)")
      Button {
        lab.startThread()
      } label: {
        HStack(spacing: 5) {
          Text("Start")
          Image(systemName: "return").font(.system(size: 9.5, weight: .bold))
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(canStart ? 1 : 0.35)))
      }
      .buttonStyle(PressStyle())
      .disabled(!canStart)
      .help("Start (Return)")
    }
  }
}

private struct LaunchChecklist: View {
  let steps: [String]
  let done: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        HStack(spacing: 8) {
          ZStack {
            if index < done {
              Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else if index == done {
              ProgressView().controlSize(.mini)
            } else {
              Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1).frame(width: 8, height: 8)
            }
          }
          .frame(width: 14, height: 14)
          Text(step)
            .font(.system(size: 12))
            .foregroundStyle(index <= done ? .white : .secondary)
        }
        .transition(.blurReplace)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}
