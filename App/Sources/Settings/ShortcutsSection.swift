import AppKit
import DesignSystem
import DictationCore
import Hotkeys
import SwiftUI

/// A row's button records a new shortcut through `ShortcutRecorder`: a
/// chord or a double tap saves at once. On the push-to-talk row, one key pressed and released
/// alone opens the hold card instead. Esc stops, and a refused shortcut says why and
/// keeps listening.
struct ShortcutsSection: View {
  let shortcuts: Shortcuts
  let actions: [HotkeyAction]
  @State private var recording: HotkeyAction?
  @State private var recorder: ShortcutRecorder?
  @State private var held: HeldKeys = []
  @State private var offer: HoldOffer?
  @State private var errors: [HotkeyAction: String] = [:]
  @State private var keys = KeyMonitor()
  @Environment(\.controlActiveState) private var windowState

  static let order: [HotkeyAction] = [.toggle, .pushToTalk, .cancel, .pasteLast]

  init(shortcuts: Shortcuts, actions: [HotkeyAction] = order) {
    self.shortcuts = shortcuts
    self.actions = actions
  }

  var body: some View {
    if let availability {
      StatusRow(title: availability.title, detail: availability.detail, status: availability.status)
    }
    ForEach(actions, id: \.self) { action in
      SettingRow(action.title) {
        subtitle(action)
      } control: {
        HStack(spacing: Space.xs.points) {
          recorderButton(action)
          resetButton(action)
        }
      }
      .disabled(shortcuts.availability != .ready)
      if action == .pushToTalk {
        pushToTalkExtras
      }
    }
    .onChange(of: windowState) { _, state in
      if state != .key { stopRecording() }
    }
    .onDisappear { stopRecording() }
  }

  /// A refused shortcut replaces the hint only until the next key goes down, so the row never
  /// sits on an error while it listens.
  @ViewBuilder private func subtitle(_ action: HotkeyAction) -> some View {
    if recording == action, offer == nil {
      VStack(alignment: .leading, spacing: Space.xs.points) {
        if let error = errors[action] {
          Label {
            Text("\(error) Try another.")
          } icon: {
            StatusIcon(.attention)
          }
        } else {
          Text(action.listeningHint)
        }
        HeldKeyCaps(held: held)
      }
    } else if let error = errors[action], offer == nil {
      Label {
        Text(error)
      } icon: {
        StatusIcon(.attention)
      }
    } else {
      Text(action.detail)
    }
  }

  @ViewBuilder private var pushToTalkExtras: some View {
    Group {
      if let offer {
        HoldOfferCard(
          offer: offer, trial: shortcuts.trial, error: errors[.pushToTalk],
          useIt: { useHold(offer.key) },
          pickAnother: pickAnother
        )
        .transition(.opacity)
      }
    }
    .motion(.keyCap, value: offer)
  }

  private func recorderButton(_ action: HotkeyAction) -> some View {
    Button {
      recording == action ? stopRecording() : startRecording(action)
    } label: {
      Text(recorderTitle(action))
        .monospacedDigit()
        .frame(minWidth: Space.xxxl.points * 3)
    }
    .appButton(recording == action ? .primary : .secondary)
    .accessibilityLabel("\(action.title) shortcut")
    .accessibilityValue(recording == action ? "Listening" : spokenLabel(action))
  }

  private func resetButton(_ action: HotkeyAction) -> some View {
    let defaultTrigger = HotkeyBindings.defaults.trigger(for: action)
    return Button {
      do throws(RebindError) {
        try shortcuts.reset(action)
        errors[action] = nil
      } catch {
        errors[action] = message(for: error, trigger: defaultTrigger)
      }
      if recording == action { stopRecording() }
    } label: {
      Image(systemName: "arrow.counterclockwise")
    }
    .appButton(.quiet, size: .small)
    .help("Reset to \(defaultTrigger?.accessibilityDescription ?? "default")")
    .accessibilityLabel("Reset \(action.title) to default")
    .opacity(shortcuts.bindings.trigger(for: action) == defaultTrigger ? 0 : 1)
    .disabled(shortcuts.bindings.trigger(for: action) == defaultTrigger)
  }

  private func recorderTitle(_ action: HotkeyAction) -> String {
    guard recording == action else { return chordLabel(action) }
    return "Cancel"
  }

  private func chordLabel(_ action: HotkeyAction) -> String {
    shortcuts.bindings.trigger(for: action)?.label ?? "Not set"
  }

  private func spokenLabel(_ action: HotkeyAction) -> String {
    shortcuts.bindings.trigger(for: action)?.accessibilityDescription ?? "Not set"
  }

  private func startRecording(_ action: HotkeyAction) {
    stopRecording()
    recording = action
    recorder = ShortcutRecorder(recording: action)
    errors[action] = nil
    shortcuts.setRecording(true)
    keys.start { event in handle(event, recording: action) }
  }

  private func stopRecording() {
    keys.stop()
    shortcuts.endTrial()
    offer = nil
    guard recording != nil else { return }
    recording = nil
    recorder = nil
    held = []
    shortcuts.setRecording(false)
  }

  /// Returns whether the event is consumed, so a chord such as ⌘Q never reaches the menu.
  private func handle(_ event: KeyEvent, recording action: HotkeyAction) -> Bool {
    let isKeyDown = if case .down = event { true } else { false }
    if offer != nil {
      if case .down(.escape, let modifiers, _) = event, modifiers.isEmpty {
        stopRecording()
        return true
      }
      return false
    }
    guard var recorder else { return false }
    let step = recorder.handle(event, at: .now())
    self.recorder = recorder
    switch step {
    case .none:
      break
    case .held(let next):
      if !next.isEmpty { errors[action] = nil }
      held = next
    case .save(let trigger):
      record(trigger, for: action)
    case .offerHold(let key):
      held = []
      errors[action] = nil
      offer = HoldOffer(key: key, warning: KeyboardFacts.warning(for: key))
      shortcuts.beginTrial(key)
    case .stop:
      stopRecording()
    case .unsupportedKey:
      errors[action] = "That key can't be used."
    }
    return isKeyDown
  }

  private func record(_ trigger: HotkeyTrigger, for action: HotkeyAction) {
    do throws(RebindError) {
      try shortcuts.rebind(action, to: trigger)
      errors[action] = nil
      stopRecording()
    } catch {
      errors[action] = message(for: error, trigger: trigger)
    }
  }

  /// The trial ends with the recording on success, and stays live beside the error otherwise.
  private func useHold(_ key: HoldKey) {
    record(.hold(key), for: .pushToTalk)
  }

  private func pickAnother() {
    shortcuts.endTrial()
    offer = nil
    held = []
    errors[.pushToTalk] = nil
    recorder = ShortcutRecorder(recording: .pushToTalk)
  }

  private func message(for error: RebindError, trigger: HotkeyTrigger?) -> String {
    switch error {
    case .invalid(.duplicate(_, let owner)):
      "\(owner.title) already uses \(trigger?.label ?? "it")."
    case .invalid(.cannotHold):
      "Push to talk needs a shortcut you can hold."
    case .invalid(.holdIsPushToTalkOnly):
      "Holding one key works only for push to talk."
    case .invalid(.overlaps(_, let owner)):
      "\(owner.title) uses a double tap of that key."
    case .invalid(.unsafe(.paste)):
      "⌘V is the paste shortcut."
    case .invalid(.unsafe):
      "Add ⌘, ⌃ or ⌥, or use a function key, so normal typing isn't caught."
    case .persistFailed:
      "Couldn't save the shortcut. Try again."
    case .unavailable:
      "Shortcuts aren't running. Restart OpenVocally to try again."
    }
  }

  private var availability: (title: String, detail: String, status: Status)? {
    switch shortcuts.availability {
    case .ready: nil
    case .starting: ("Starting shortcuts", "This takes a moment after launch.", .progress)
    case .needsAccessibility:
      ("Shortcuts are off", "Allow Accessibility above to use and change them.", .attention)
    case .failed: ("Shortcuts couldn't start", "Restart OpenVocally to try again.", .failed)
    }
  }
}

extension HotkeyAction {
  var title: String {
    switch self {
    case .toggle: "Toggle recording"
    case .pushToTalk: "Push to talk"
    case .cancel: "Cancel"
    case .pasteLast: "Paste last transcript"
    }
  }

  var detail: String {
    switch self {
    case .toggle: "Press once to start, again to stop."
    case .pushToTalk: "Hold to record, release to stop."
    case .cancel: "Stops a recording or a transcription in progress."
    case .pasteLast: "Pastes your latest transcript where you're typing."
    }
  }

  /// Bare Esc is the cancel row's own default, so that row stops on a second click instead.
  /// Push to talk refuses double taps, so its hint leaves them out.
  var listeningHint: String {
    switch self {
    case .cancel: "Press a shortcut or double-tap a modifier. Click again to stop."
    case .pushToTalk: "Press and hold a key, or press a shortcut."
    case .toggle, .pasteLast: "Press a shortcut or double-tap a modifier. Esc stops."
    }
  }
}

/// The key presses in this app's windows while a shortcut is recorded. The hotkey tap is
/// paused meanwhile, so the chords it owns arrive here too. Events are parsed by the same
/// `KeyEvent` translation as the tap, so sides and Fn read alike in both.
@MainActor final class KeyMonitor {
  private var monitor: Any?

  func start(_ handler: @escaping @MainActor (KeyEvent) -> Bool) {
    stop()
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
      let kind: KeyEvent.Kind =
        switch event.type {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        default: .flagsChanged
        }
      let parsed = KeyEvent(
        kind, keyCode: KeyCode(rawValue: event.keyCode), rawFlags: UInt64(event.modifierFlags.rawValue),
        isAutorepeat: kind == .keyDown && event.isARepeat)
      return handler(parsed) ? nil : event
    }
  }

  func stop() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }
}
