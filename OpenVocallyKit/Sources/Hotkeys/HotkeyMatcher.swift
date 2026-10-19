import DictationCore

public enum KeyEvent: Sendable, Equatable {
  case down(KeyCode, Modifiers, isAutorepeat: Bool = false)
  case up(KeyCode, Modifiers)
  /// Every hold key down after a flags change, by side. Always passed on.
  case modifiersChanged(HeldKeys)
  /// A mouse button went down. Always passed on; it ends a double tap or a one-key hold.
  case pointerDown

  /// The raw event kinds both producers see.
  public enum Kind: Sendable { case keyDown, keyUp, flagsChanged, pointerDown }

  /// The single translation from raw event fields, shared by the tap (CGEvent) and the
  /// Settings recorder (NSEvent).
  public init(_ kind: Kind, keyCode: KeyCode, rawFlags: UInt64, isAutorepeat: Bool) {
    let held = HeldKeys(
      rawFlags: rawFlags, changedKey: kind == .flagsChanged ? keyCode : nil,
      isFlagsChange: kind == .flagsChanged)
    switch kind {
    case .flagsChanged: self = .modifiersChanged(held)
    case .keyDown: self = .down(keyCode, held.modifiers, isAutorepeat: isAutorepeat)
    case .keyUp: self = .up(keyCode, held.modifiers)
    case .pointerDown: self = .pointerDown
    }
  }
}

public enum Disposition: Sendable, Equatable {
  case pass
  case consume
}

public struct Verdict: Sendable, Equatable {
  let disposition: Disposition
  /// In order. Two only when a key-down both ends a one-key hold and fires its own chord,
  /// such as Right ⌘ held, then ⌘K bound to toggle: [.holdAbort, .toggle].
  public let emits: [DictationCommand]

  public init(_ disposition: Disposition, emit: DictationCommand? = nil) {
    self.init(disposition, emits: emit.map { [$0] } ?? [])
  }

  init(_ disposition: Disposition, emits: [DictationCommand]) {
    self.disposition = disposition
    self.emits = emits
  }

  public static let pass = Verdict(.pass)
}

/// What the tap is listening for. One owner replaces a paused flag.
public enum ListenMode: Sendable, Equatable {
  /// Bindings fire.
  case live
  /// The recorder is open; every fresh key-down passes and nothing starts. Key-ups keep
  /// their handling, so a chord hold started before still stops on release.
  case recording
  /// Try it in the setup card: `key` held alone starts a trial hold. Bindings stay quiet as in
  /// `.recording`. Nothing is stored.
  case trial(HoldKey)
}

/// All hotkey state in one value. Every transition returns what to emit.
public struct HotkeyMatcher: Sendable {
  public private(set) var bindings: HotkeyBindings
  public private(set) var mode: ListenMode = .live
  private var cancelArmed = false
  /// The ⌘V watcher. Armed only while the manual paste window is open, so every way
  /// out of that phase removes it.
  private var manualPasteArmed = false

  /// The only copy of the push-to-talk hold, whichever trigger made it.
  enum HoldState: Sendable, Equatable {
    case none
    /// A chord push to talk; its key-up stops.
    case chord(KeyCode)
    /// A one-key hold that started. Its release stops; anything else aborts.
    case alone(HoldKey)
    /// A one-key hold that was aborted. Waits for the key's release so that letting go of
    /// the other key cannot restart it (Right ⌘ + C, release C, Right ⌘ still down).
    case spent(HoldKey)
  }

  private var hold: HoldState = .none
  /// Last flags snapshot; a one-key hold starts only on a fresh press into exactly that key.
  private var held: HeldKeys = []
  /// The bound one-key push to talk, cached from `bindings`.
  private var boundHoldKey: HoldKey?
  /// Keys whose last fresh key-down was consumed. Their autorepeats and key-up are
  /// consumed too, so the frontmost app never sees half a keystroke.
  private var swallowed: Set<KeyCode> = []
  private var doubleTap = DoubleTapDetector()

  public init(bindings: HotkeyBindings) {
    self.bindings = bindings
    boundHoldKey = Self.holdKey(in: bindings)
  }

  /// The key a fresh lone press of starts a hold, in this mode.
  private var armedKey: HoldKey? {
    switch mode {
    case .live: boundHoldKey
    case .recording: nil
    case .trial(let key): key
    }
  }

  public mutating func handle(_ event: KeyEvent, at time: HostTime) -> Verdict {
    switch event {
    case .modifiersChanged(let next):
      var emits = holdFlagsChanged(next)
      if let key = doubleTap.modifiersChanged(next.modifiers, at: time), mode == .live,
        let command = doubleTapCommand(bindings.actionByTrigger[.doubleTap(key)])
      {
        emits.append(command)
      }
      return Verdict(.pass, emits: emits)
    case .pointerDown:
      doubleTap.reset()
      return Verdict(.pass, emits: abortAlone())
    case .down(let key, let modifiers, let isAutorepeat):
      doubleTap.keyEvent(holding: modifiers)
      let aborted = abortAlone()
      let verdict = keyDown(key, modifiers, isAutorepeat: isAutorepeat)
      return Verdict(verdict.disposition, emits: aborted + verdict.emits)
    case .up(let key, let modifiers):
      doubleTap.keyEvent(holding: modifiers)
      let aborted = abortAlone()
      let verdict = keyUp(key)
      return Verdict(verdict.disposition, emits: aborted + verdict.emits)
    }
  }

  private mutating func holdFlagsChanged(_ next: HeldKeys) -> [DictationCommand] {
    defer { held = next }
    switch hold {
    case .alone(let key):
      if !next.contains(key) {
        hold = .none
        return [.pushToTalkStop]
      }
      if next != HeldKeys(key) {
        hold = .spent(key)
        return [.holdAbort]
      }
      return []
    case .spent(let key):
      if !next.contains(key) { hold = .none }
      return []
    case .none:
      guard let key = next.only, !held.contains(key), key == armedKey else { return [] }
      hold = .alone(key)
      return [.holdStart(trial: mode == .trial(key))]
    case .chord:
      return []
    }
  }

  /// `.alone` becomes `.spent` with a hold abort; anything else is left alone.
  private mutating func abortAlone() -> [DictationCommand] {
    guard case .alone(let key) = hold else { return [] }
    hold = .spent(key)
    return [.holdAbort]
  }

  /// Never touches `swallowed`: a modifier event is not a keystroke. Only cancel drops the
  /// hold, silently, as the chord cancel does.
  private mutating func doubleTapCommand(_ action: HotkeyAction?) -> DictationCommand? {
    switch action {
    case nil, .pushToTalk:
      return nil
    case .cancel:
      guard cancelArmed else { return nil }
      dropHold()
      return .cancel
    case .toggle:
      return .toggle
    case .pasteLast:
      return .pasteLast
    }
  }

  /// A cancel ends the session itself, so the hold goes without a command of its own.
  private mutating func dropHold() {
    switch hold {
    case .alone(let key): hold = .spent(key)
    case .chord: hold = .none
    case .none, .spent: break
    }
  }

  private mutating func keyDown(_ key: KeyCode, _ modifiers: Modifiers, isAutorepeat: Bool) -> Verdict {
    if isAutorepeat {
      return swallowed.contains(key) ? Verdict(.consume) : .pass
    }
    let verdict = freshDown(key, modifiers)
    if verdict.disposition == .consume {
      swallowed.insert(key)
    } else {
      // A stale entry from a lost key-up must not eat this keystroke.
      swallowed.remove(key)
    }
    return verdict
  }

  private mutating func keyUp(_ key: KeyCode) -> Verdict {
    let wasHeld = hold == .chord(key)
    if wasHeld { hold = .none }
    let wasSwallowed = swallowed.remove(key) != nil
    return Verdict(
      wasSwallowed ? .consume : .pass,
      emit: wasHeld ? .pushToTalkStop : nil
    )
  }

  private mutating func freshDown(_ key: KeyCode, _ modifiers: Modifiers) -> Verdict {
    guard mode == .live else { return .pass }
    let chord = KeyChord(key, modifiers)
    switch bindings.actionByTrigger[.chord(chord)] {
    case nil where manualPasteArmed && chord == .paste:
      // Passed on: the user's own ⌘V pastes the transcript already on the clipboard.
      return Verdict(.pass, emit: .manualPaste)
    case nil:
      return .pass
    case .cancel where !cancelArmed:
      return .pass
    case .cancel:
      dropHold()
      return Verdict(.consume, emit: .cancel)
    case .pushToTalk:
      hold = .chord(key)
      return Verdict(.consume, emit: .pushToTalkStart)
    case .toggle:
      return Verdict(.consume, emit: .toggle)
    case .pasteLast:
      return Verdict(.consume, emit: .pasteLast)
    }
  }

  /// The tap was disabled and re-enabled; a key event may have been lost, so a shortcut may
  /// have gone by unseen. A one-key hold aborts silently; a chord hold stops. Keeps
  /// `swallowed` so a key-up arriving after re-enable is still consumed.
  mutating func tapWasReset() -> DictationCommand? {
    doubleTap.reset()
    held = []
    return releaseHold()
  }

  /// Same release rule as `tapWasReset`. Keeps `swallowed` so pending key-ups of the old
  /// chords are still consumed.
  public mutating func rebind(_ bindings: HotkeyBindings) -> DictationCommand? {
    self.bindings = bindings
    boundHoldKey = Self.holdKey(in: bindings)
    doubleTap.reset()
    return releaseHold()
  }

  /// Shortcut recording, Try it trial, or live. Any change aborts a one-key hold in progress, so
  /// leaving `.trial` ends a trial hold. A chord hold keeps waiting for its key-up.
  public mutating func setMode(_ mode: ListenMode) -> DictationCommand? {
    guard mode != self.mode else { return nil }
    self.mode = mode
    doubleTap.reset()
    return abortAlone().first
  }

  /// Never touches the hold: a stale phase must not drop a real key-up.
  public mutating func phaseDidChange(to phase: DictationPhase) {
    cancelArmed = phase.intent(for: .cancel) != .ignore
    manualPasteArmed = phase.intent(for: .manualPaste) != .ignore
  }

  /// Ends in `.none`, never `.spent`: the release that would clear `.spent` may be the event
  /// that was lost. `held` still blocks a restart while the key stays down.
  private mutating func releaseHold() -> DictationCommand? {
    defer { hold = .none }
    switch hold {
    case .none, .spent: return nil
    case .chord: return .pushToTalkStop
    case .alone: return .holdAbort
    }
  }

  private static func holdKey(in bindings: HotkeyBindings) -> HoldKey? {
    if case .hold(let key) = bindings.trigger(for: .pushToTalk) { key } else { nil }
  }
}
