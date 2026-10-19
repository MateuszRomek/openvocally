import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "hotkeys")

public enum HotkeyAction: String, Sendable, Hashable, CaseIterable, Codable {
  case toggle
  case cancel
  case pushToTalk
  case pasteLast
}

/// A validated set of bindings. Holding one proves no two actions share a trigger,
/// every chord is safe to consume, and push-to-talk has something to hold.
public struct HotkeyBindings: Sendable, Equatable {
  public enum Invalid: Error, Equatable {
    case duplicate(HotkeyTrigger, owner: HotkeyAction)
    /// The tap would swallow ordinary typing, or the app's own synthetic Cmd+V paste.
    case unsafe(KeyChord)
    /// A double tap has no hold, so it cannot drive push-to-talk.
    case cannotHold(HotkeyTrigger)
    /// A one-key hold bound to anything but push to talk: a tap of it would fire on every
    /// stray press.
    case holdIsPushToTalkOnly(HotkeyTrigger)
    /// A one-key hold and a double tap of the same modifier family: each tap would start a
    /// provisional recording.
    case overlaps(HotkeyTrigger, owner: HotkeyAction)
  }

  /// The lookup the tap does per event.
  let actionByTrigger: [HotkeyTrigger: HotkeyAction]

  public init(_ triggers: [HotkeyAction: HotkeyTrigger]) throws(Invalid) {
    var index: [HotkeyTrigger: HotkeyAction] = [:]
    for action in HotkeyAction.allCases {
      guard let trigger = triggers[action] else { continue }
      try Self.validate(trigger, for: action)
      if let owner = Self.overlap(of: trigger, in: index) { throw .overlaps(trigger, owner: owner) }
      if let owner = index.updateValue(action, forKey: trigger) {
        throw .duplicate(trigger, owner: owner)
      }
    }
    actionByTrigger = index
  }

  private init(index: [HotkeyTrigger: HotkeyAction]) {
    actionByTrigger = index
  }

  public func trigger(for action: HotkeyAction) -> HotkeyTrigger? {
    actionByTrigger.first { $0.value == action }?.key
  }

  public var triggers: [HotkeyAction: HotkeyTrigger] {
    Dictionary(uniqueKeysWithValues: actionByTrigger.map { ($0.value, $0.key) })
  }

  /// Rebinding an action to its own trigger succeeds and changes nothing.
  public func replacing(_ action: HotkeyAction, with trigger: HotkeyTrigger) throws(Invalid) -> HotkeyBindings
  {
    if let owner = actionByTrigger[trigger] {
      guard owner == action else { throw .duplicate(trigger, owner: owner) }
      return self
    }
    try Self.validate(trigger, for: action)
    var index = actionByTrigger.filter { $0.value != action }
    if let owner = Self.overlap(of: trigger, in: index) { throw .overlaps(trigger, owner: owner) }
    index[trigger] = action
    return HotkeyBindings(index: index)
  }

  /// Every double tap is safe: modifier events are never consumed. A chord on a modifier's own
  /// keycode is refused, so storage can read such a row as a double tap.
  private static func validate(_ trigger: HotkeyTrigger, for action: HotkeyAction) throws(Invalid) {
    switch trigger {
    case .doubleTap:
      if action == .pushToTalk { throw .cannotHold(trigger) }
    case .hold:
      if action != .pushToTalk { throw .holdIsPushToTalkOnly(trigger) }
    case .chord(let chord):
      if chord == .paste || ModifierKey(keyCode: chord.key) != nil { throw .unsafe(chord) }
      let hasHoldModifier = !chord.modifiers.isDisjoint(with: [.command, .control, .option])
      guard hasHoldModifier || action == .cancel || KeyCode.functionKeys.contains(chord.key) else {
        throw .unsafe(chord)
      }
    }
  }

  /// The action whose double tap shares a family with this hold, or the reverse.
  private static func overlap(of trigger: HotkeyTrigger, in index: [HotkeyTrigger: HotkeyAction])
    -> HotkeyAction?
  {
    switch trigger {
    case .hold(let key):
      guard let family = key.family else { return nil }
      return index[.doubleTap(family)]
    case .doubleTap(let family):
      return index.first { entry in
        if case .hold(let key) = entry.key { key.family == family } else { false }
      }?.value
    case .chord:
      return nil
    }
  }

  /// The defaults: ⌥D to toggle, because a double tap of ⌥ fired by accident, ⌥Space
  /// to hold, and ⌃⌥V because ⇧⌘V is Paste and Match Style in many apps. Built from the reverse
  /// index so it needs no `try`.
  public static let defaults = HotkeyBindings(index: [
    .chord(KeyChord(.d, [.option])): .toggle,
    .chord(KeyChord(.escape)): .cancel,
    .chord(KeyChord(.space, [.option])): .pushToTalk,
    .chord(KeyChord(.v, [.control, .option])): .pasteLast,
  ])
}

extension HotkeyBindings {
  /// How stored bindings load. Nothing stored, or an unusable set, loads the defaults. An action
  /// missing from storage, such as one added in a later version, takes its default trigger unless
  /// a stored action already owns it; then it stays unbound. Unknown action names are ignored.
  public static func loading(stored: [String: HotkeyTrigger]) -> HotkeyBindings {
    guard !stored.isEmpty else { return .defaults }
    var triggers: [HotkeyAction: HotkeyTrigger] = [:]
    for (name, trigger) in stored {
      if let action = HotkeyAction(rawValue: name) { triggers[action] = trigger }
    }
    var bindings: HotkeyBindings
    do {
      bindings = try HotkeyBindings(triggers)
    } catch {
      logger.error(
        "Stored hotkey bindings unusable, using defaults: \(String(describing: error), privacy: .public)")
      return .defaults
    }
    for action in HotkeyAction.allCases where bindings.trigger(for: action) == nil {
      guard let trigger = HotkeyBindings.defaults.trigger(for: action) else { continue }
      do {
        bindings = try bindings.replacing(action, with: trigger)
      } catch {
        logger.notice(
          "Default hotkey for \(action.rawValue, privacy: .public) is taken by a saved one; leaving it unbound"
        )
      }
    }
    return bindings
  }
}
