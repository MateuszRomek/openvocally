import ApplicationServices
import Dictation
import Hotkeys
import Observation
import Storage
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "app")

/// The global shortcuts and what they depend on: Accessibility, the stored bindings and the
/// push-to-talk Try it. The only writer of the hotkey mode, the bindings and the Accessibility
/// state.
@MainActor @Observable final class Shortcuts {
  private(set) var availability = HotkeyAvailability.starting
  private(set) var bindings = HotkeyBindings.defaults
  private(set) var accessibilityGranted = AXIsProcessTrusted() {
    didSet {
      guard accessibilityGranted != oldValue else { return }
      logger.notice("Accessibility granted: \(self.accessibilityGranted, privacy: .public)")
    }
  }
  /// What the push-to-talk card shows during Try it; nil outside it.
  private(set) var trial: HoldTrial?

  /// Whether the start loop may raise the Accessibility alert. Off while onboarding is or has
  /// been on screen, since a permission skipped there is left to the Home banner, and off after
  /// the first alert.
  @ObservationIgnored var promptsForAccessibility: Bool

  @ObservationIgnored private var hotkeys: Hotkeys?
  @ObservationIgnored private let history: History
  /// The database the running bindings were loaded from, and the only one they are saved to.
  /// When the launch open failed, the hotkeys run on the defaults and this stays nil until Try
  /// Again loads the stored bindings, since saving the defaults would overwrite the user's
  /// stored shortcuts.
  @ObservationIgnored private var store: AppDatabase?

  init(history: History, promptsForAccessibility: Bool) {
    self.history = history
    self.promptsForAccessibility = promptsForAccessibility
  }

  /// Loads the stored bindings off the main actor, then starts the hotkeys, retrying once a
  /// second until Accessibility is granted. Returns nil only when cancelled.
  func start() async -> Hotkeys? {
    let database = history.database
    store = database
    if let database {
      bindings = await Task.detached { database.loadHotkeyBindings() }.value
    }
    while !Task.isCancelled {
      do throws(HotkeysStartError) {
        let hotkeys = try await Hotkeys.start(bindings: bindings)
        // Try Again can load the stored bindings while the tap starts.
        if hotkeys.bindings != bindings { hotkeys.replaceBindings(bindings) }
        accessibilityGranted = true
        availability = .ready
        self.hotkeys = hotkeys
        return hotkeys
      } catch .accessibilityNotGranted {
        accessibilityGranted = false
        availability = .needsAccessibility
        if promptsForAccessibility { requestAccessibility() }
      } catch {
        availability = HotkeyAvailability(error)
        logger.error("Hotkeys failed to start: \(String(describing: error), privacy: .public)")
      }
      try? await Task.sleep(for: .seconds(1))
    }
    return nil
  }

  /// Try Again opened the database the launch could not. Loads the stored bindings into the
  /// running hotkeys before saving to it, so a later change never overwrites them with the
  /// defaults.
  func adoptStore(_ database: AppDatabase) async {
    guard store == nil else { return }
    let stored = await Task.detached { database.loadHotkeyBindings() }.value
    guard store == nil else { return }
    // A swap releases a held push-to-talk, so skip it when nothing changed.
    if let hotkeys, hotkeys.bindings != stored { hotkeys.replaceBindings(stored) }
    bindings = stored
    store = database
  }

  /// Accessibility changes in System Settings, so it is read again on every check.
  private func refreshAccessibility() {
    accessibilityGranted = AXIsProcessTrusted()
  }

  /// Checks the hotkeys' grants and tap, and shows the result. Returns whether the tap is
  /// installed; a suspended one needs Accessibility again.
  @discardableResult func check(_ hotkeys: Hotkeys, reason: String) async -> Bool {
    let installed = await hotkeys.ensureEnabled(reason: reason)
    availability = installed ? .ready : .needsAccessibility
    refreshAccessibility()
    return installed
  }

  func stop() {
    hotkeys?.stop()
  }

  /// Whether `update` belongs to the Try it card, which then takes it so the overlay never sees
  /// it.
  func absorb(_ update: DictationUpdate) -> Bool {
    guard HoldTrial.claims(update, trialActive: trial != nil) else { return false }
    if let trial { self.trial = trial.applying(update) }
    return true
  }

  func trialHeard(level: Float) {
    if let next = trial?.heard(level: level) { trial = next }
  }

  /// The onboarding's Accessibility step. The start loop keeps polling, so the grant shows up
  /// within a second of the switch in System Settings.
  func requestAccessibility() {
    promptsForAccessibility = false
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// The tap lets every key through while the recorder listens.
  func setRecording(_ recording: Bool) {
    hotkeys?.setMode(recording ? .recording : .live)
  }

  /// Try it in Settings: no overlay, no paste and no LB-01.
  func beginTrial(_ key: HoldKey) {
    hotkeys?.setMode(.trial(key))
    trial = .waiting
  }

  func endTrial() {
    guard trial != nil else { return }
    hotkeys?.setMode(.recording)
    trial = nil
  }

  func rebind(_ action: HotkeyAction, to trigger: HotkeyTrigger) throws(RebindError) {
    guard let hotkeys else { throw .unavailable }
    let database = store
    try hotkeys.rebind(action, to: trigger) { bindings in
      guard let database else { throw HotkeyStoreUnavailable() }
      try database.saveHotkeyBindings(bindings)
    }
    bindings = hotkeys.bindings
  }

  func reset(_ action: HotkeyAction) throws(RebindError) {
    guard let trigger = HotkeyBindings.defaults.trigger(for: action) else { return }
    try rebind(action, to: trigger)
  }
}

/// The database isn't open, so a changed shortcut has nowhere to be saved.
private struct HotkeyStoreUnavailable: Error {}
