import AppKit
import SwiftUI

@main struct LabApp: App {
  @NSApplicationDelegateAdaptor private var delegate: LabDelegate

  var body: some Scene {
    Window("Notch Agents Lab", id: "lab") {
      ControlPanel(lab: delegate.lab, displays: delegate.displays)
    }
    .windowResizability(.contentSize)
  }
}

@Observable final class Displays {
  var summary = ""
}

final class LabDelegate: NSObject, NSApplicationDelegate {
  let lab = Lab()
  let displays = Displays()
  private var stage: Stage?
  private var monitors: [Any] = []
  private var screenObserver: (any NSObjectProtocol)?
  private var activationObserver: (any NSObjectProtocol)?
  private var rightCommandDown = false
  private var rightOptionDown = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    // Scripted screenshot runs leave the keyboard with whatever app you are typing in.
    if !CommandLine.arguments.contains("--passive") { NSApp.activate() }
    let stage = Stage(lab: lab)
    self.stage = stage
    displays.summary = stage.displaySummary
    playDemo()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screensChanged() }
    }
    // Switching apps, by ⌘Tab or a click, parks the start card as a draft.
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      // The lab activating itself, at launch or from its control window, isn't switching away.
      guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
      MainActor.assumeIsolated { self?.lab.parkDraft() }
    }
    monitors.append(
      NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
        guard let self else { return event }
        return handleKey(event) ? nil : event
      } as Any)
    // Right ⌘ is agent mode and right ⌥ is dictation, from any app when the launching terminal has
    // Accessibility access, and in the lab otherwise.
    monitors.append(
      NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
        self?.handleFlags(event)
        return event
      } as Any)
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
        MainActor.assumeIsolated { self?.handleFlags(event) }
      } as Any)
    // ⌥↩ and ⌥⎋ answer an approval from any app. A global monitor can't swallow the key, so the
    // frontmost app sees it too; the real app captures it only while an approval is pending.
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        MainActor.assumeIsolated { _ = self?.handleAnswerKey(event) }
      } as Any)
  }

  /// `[--backdrop shoulders|shadow|pill] [--resting] [--preview] [--demo busy|needs|answer|many|failed|record|agent]
  /// [--size compact|roomy|large] [--thread <id>] [--passive] [--open]`, with
  /// `--open` last: AppKit reads `--open x` as a defaults pair and opens a leftover word as a file.
  /// sets up a scene on launch, for screenshots without driving the control window.
  private func playDemo() {
    let args = CommandLine.arguments
    func value(_ flag: String) -> String? {
      args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    if let backdrop = value("--backdrop") {
      lab.backdrop = Backdrop.allCases.first { "\($0)" == backdrop } ?? .plain
    }
    if args.contains("--resting") { lab.idleOnNotchless = .resting }
    if args.contains("--preview") { lab.panelLayout = .preview }
    if args.contains("--passive") { lab.passive = true }
    if let arrival = value("--arrival") { lab.arrival = ApprovalArrival.allCases.first { "\($0)" == arrival } ?? .card }
    if let queue = value("--queue") { lab.approvalQueue = ApprovalQueue.allCases.first { "\($0)" == queue } ?? .oneAtATime }
    if args.contains("--one-line") { lab.commandLength = .oneLine }
    if args.contains("--everywhere") { lab.scope = .all }
    if args.contains("--main") { lab.scope = .main }
    if let look = value("--look") { lab.cardLook = CardLook.allCases.first { "\($0)" == look } ?? .calm }
    if args.contains("--hints") { lab.shortcutsHeld = true }
    if let keys = value("--keys") { lab.pickerKeys = PickerKeys.allCases.first { "\($0)" == keys } ?? .numbered }
    if args.contains("--prompt-text") { lab.promptStyle = .text }
    if args.contains("--worktree") { lab.lastSettings.worktree = true }
    if let mark = value("--mark") { lab.draftMark = DraftMark.allCases.first { "\($0)" == mark } ?? .word }
    // Holds agent mode once the cards are up, to show the card's voice-deny state.
    if let delay = value("--speak-after").flatMap(Double.init) {
      Task {
        try? await Task.sleep(for: .seconds(delay))
        lab.press(agentMode: true)
      }
    }
    if args.contains("--allow-menu") { lab.allowPlacement = .menu }
    if let size = value("--size") { lab.threadSize = ThreadSize.allCases.first { "\($0)" == size } ?? .roomy }
    switch value("--demo") {
    case "busy": lab.play(.busy)
    case "needs": lab.play(.needsYou)
    case "answer": lab.play(.answer)
    case "many": lab.play(.many)
    case "failed": lab.play(.failed)
    case "record": lab.press(agentMode: false)
    case "agent": lab.press(agentMode: true)
    case "approvals": lab.play(.threeApprovals)
    case "long": lab.play(.longCommand)
    case "tail": lab.play(.riskyTail)
    case "start": lab.newThreadKey()
    case "spoken": lab.play(.speakNew)
    case "card-approval": lab.play(.approvalDuringCard)
    case "draft":
      lab.play(.speakNew)
      Task {
        try? await Task.sleep(for: .seconds(3.5))
        lab.parkDraft()
      }
    default: break
    }
    let thread = value("--thread").flatMap(Int.init)
    if args.contains("--open") || thread != nil {
      Task {
        try? await Task.sleep(for: .seconds(2.5))
        lab.open(.expanded, on: NSScreen.main?.screenID ?? 0)
        if let thread { lab.show(thread: thread) }
      }
    }
  }


  /// ⌥↩ allows and ⌥⎋ denies the front approval card.
  private func handleAnswerKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    // ⌥T starts a new thread from any app.
    if flags == .option, event.keyCode == 17, !event.isARepeat {
      lab.newThreadKey()
      return true
    }
    guard flags == .option, !event.isARepeat, !lab.approvalOrder.isEmpty else { return false }
    switch event.keyCode {
    case 36: lab.answerFromKeyboard(allow: true)
    case 53: lab.answerFromKeyboard(allow: false)
    default: return false
    }
    return true
  }

  private func screensChanged() {
    stage?.rebuild()
    displays.summary = stage?.displaySummary ?? ""
  }

  private func handleFlags(_ event: NSEvent) {
    let flags = event.modifierFlags
    switch event.keyCode {
    case 55:
      let down = flags.contains(.command)
      if down != lab.shortcutsHeld { withAnimation(.easeOut(duration: 0.12)) { lab.shortcutsHeld = down } }
    case 54:
      let down = flags.contains(.command)
      guard down != rightCommandDown else { return }
      rightCommandDown = down
      down ? lab.press(agentMode: true) : lab.release()
    case 61:
      let down = flags.contains(.option)
      guard down != rightOptionDown else { return }
      rightOptionDown = down
      down ? lab.press(agentMode: false) : lab.release()
    default:
      break
    }
  }

  /// Space and A hold to talk, O opens the panel, Esc closes it. Keys typed into the notch panel
  /// pass through untouched.
  private func handleKey(_ event: NSEvent) -> Bool {
    if lab.openLevel == .start, event.window is NotchPanel { return lab.cardKey(event) }
    guard !(event.window is NotchPanel) else { return false }
    if event.type == .keyDown, handleAnswerKey(event) { return true }
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
    else { return false }
    let key = event.charactersIgnoringModifiers ?? ""
    if key == " " || key == "a" {
      if event.type == .keyDown, !event.isARepeat { lab.press(agentMode: key == "a") }
      if event.type == .keyUp { lab.release() }
      return true
    }
    guard event.type == .keyDown, !event.isARepeat else { return false }
    switch key {
    case "o": lab.toggleOpen()
    case "t": lab.newThreadKey()
    case "\u{1b}": lab.escape()
    default: return false
    }
    return true
  }
}

private struct ControlPanel: View {
  @Bindable var lab: Lab
  let displays: Displays

  var body: some View {
    Form {
      Section("Displays") {
        Text(displays.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        Picker("Show on", selection: $lab.scope) {
          ForEach(DisplayScope.allCases) { Text($0.rawValue).tag($0) }
        }
        Toggle("Treat a real notch as missing", isOn: $lab.forceNotchless)
      }
      Section("Display without a notch") {
        Picker("Surface", selection: $lab.backdrop) {
          ForEach(Backdrop.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Simulated notch height", selection: simulatedHeight) {
          ForEach(SimulatedHeight.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("When idle", selection: $lab.idleOnNotchless) {
          ForEach(IdleOnNotchless.allCases) { Text($0.rawValue).tag($0) }
        }
      }
      Section("Behavior") {
        Picker("Hover", selection: $lab.hover) {
          ForEach(HoverBehavior.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Hover zone below the notch", selection: $lab.hoverReach) {
          ForEach(HoverReach.allCases) { Text($0.rawValue).tag($0) }
        }
        Toggle("Outline the hover zone", isOn: $lab.showHoverZone)
        Picker("Open panel closes when", selection: $lab.close) {
          ForEach(CloseBehavior.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Open motion", selection: $lab.openMotion) {
          ForEach(OpenMotion.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Open panel", selection: $lab.panelLayout) {
          ForEach(PanelLayout.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Thread size", selection: $lab.threadSize) {
          ForEach(ThreadSize.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Working", selection: $lab.working) {
          ForEach(WorkingIndicator.allCases) { Text($0.rawValue).tag($0) }
        }
        Toggle("Agent mode names the thread while you speak", isOn: $lab.showTarget)
        Toggle("Slow motion (4× slower)", isOn: $lab.slowMotion)
        Toggle("Reduce Motion (no springs)", isOn: $lab.reduceMotion)
      }
      Section("Approvals") {
        Picker("When one arrives", selection: $lab.arrival) {
          ForEach(ApprovalArrival.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Several at once", selection: $lab.approvalQueue) {
          ForEach(ApprovalQueue.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Command", selection: $lab.commandLength) {
          ForEach(CommandLength.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Allow for this thread", selection: $lab.allowPlacement) {
          ForEach(AllowPlacement.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Card stays", selection: $lab.cardLinger) {
          ForEach(CardLinger.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Agent mode speaks to", selection: $lab.voiceTarget) {
          ForEach(VoiceTarget.allCases) { Text($0.rawValue).tag($0) }
        }
      }
      Section("Start card") {
        Picker("Look", selection: $lab.cardLook) {
          ForEach(CardLook.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Picker keys", selection: $lab.pickerKeys) {
          ForEach(PickerKeys.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Prompt", selection: $lab.promptStyle) {
          ForEach(PromptStyle.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("⌥T", selection: $lab.newThreadKeyBehavior) {
          ForEach(NewThreadKey.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("⌥T with a draft waiting", selection: $lab.draftOnNew) {
          ForEach(DraftOnNew.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Agent mode into an open card", selection: $lab.respeak) {
          ForEach(Respeak.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Draft mark", selection: $lab.draftMark) {
          ForEach(DraftMark.allCases) { Text($0.rawValue).tag($0) }
        }
        LabeledContent("Keys pressed in the last card", value: "\(lab.cardKeys)")
        HStack {
          Button("New thread (⌥T)") { lab.newThreadKey() }
          Button(Lab.Scenario.speakNew.rawValue) { lab.play(.speakNew) }
          Button(Lab.Scenario.speakAgain.rawValue) { lab.play(.speakAgain) }
        }
        Button(Lab.Scenario.approvalDuringCard.rawValue) { lab.play(.approvalDuringCard) }
      }
      Section("Sequences") {
        HStack {
          ForEach(Lab.Scenario.allCases.prefix(4)) { scenario in
            Button(scenario.rawValue) { lab.play(scenario) }
          }
        }
        HStack {
          ForEach(Lab.Scenario.allCases.dropFirst(4).prefix(4)) { scenario in
            Button(scenario.rawValue) { lab.play(scenario) }
          }
        }
        HStack {
          ForEach(Lab.Scenario.allCases.dropFirst(8).filter { ![.speakNew, .speakAgain, .approvalDuringCard].contains($0) }) { scenario in
            Button(scenario.rawValue) { lab.play(scenario) }
          }
        }
        HStack {
          Button("Open panel") { lab.toggleOpen() }
          Button("Close") { lab.closeAll() }
        }
      }
      Section {
        Text(
          """
          Here: hold Space to dictate, hold A for agent mode into the selected thread, O opens, Esc closes.
          Anywhere: hold right ⌥ to dictate, right ⌘ for agent mode (needs Accessibility for the terminal).
          Hover the notch to peek; click it to open. In the list: ↑ ↓ and Return open a thread. In a thread: Esc or ⌘[ goes back, ⌘O hands off to the main window, ⌘↩ allow, ⌘⌫ deny.
          An approval card in the closed notch: click Allow or Deny, or ⌥↩ and ⌥⎋ from any app. Hold A or right ⌘ while it shows to deny it by voice.
          New thread: T here or ⌥T anywhere opens the start card. Return starts, Esc steps back then discards, clicking another app parks it as a draft. Right ⌘ speaks into the card, right ⌥ dictates at its caret.
          """
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 560)
  }

  private var simulatedHeight: Binding<SimulatedHeight> {
    Binding(
      get: { lab.simulatedHeight },
      set: {
        lab.simulatedHeight = $0
        lab.onLayoutChange?()
      })
  }
}
