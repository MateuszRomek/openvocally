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
    if let size = value("--size") { lab.threadSize = ThreadSize.allCases.first { "\($0)" == size } ?? .roomy }
    switch value("--demo") {
    case "busy": lab.play(.busy)
    case "needs": lab.play(.needsYou)
    case "answer": lab.play(.answer)
    case "many": lab.play(.many)
    case "failed": lab.play(.failed)
    case "record": lab.press(agentMode: false)
    case "agent": lab.press(agentMode: true)
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


  private func screensChanged() {
    stage?.rebuild()
    displays.summary = stage?.displaySummary ?? ""
  }

  private func handleFlags(_ event: NSEvent) {
    let flags = event.modifierFlags
    switch event.keyCode {
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
    guard !(event.window is NotchPanel) else { return false }
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
      Section("Sequences") {
        HStack {
          ForEach(Lab.Scenario.allCases.prefix(4)) { scenario in
            Button(scenario.rawValue) { lab.play(scenario) }
          }
        }
        HStack {
          ForEach(Lab.Scenario.allCases.dropFirst(4)) { scenario in
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
