import DictationCore

@testable import Hotkeys

extension HotkeyMatcher {
  /// For tests where only the order of key events matters.
  mutating func handle(_ event: KeyEvent) -> Verdict {
    handle(event, at: HostTime(ticks: 0))
  }
}

extension HotkeyBindings {
  /// The earlier all-chord defaults, which most matcher tests were written against.
  static let chordFixture: HotkeyBindings = {
    do {
      return try HotkeyBindings([
        .toggle: .chord(KeyChord(.space, [.command, .shift])),
        .cancel: .chord(KeyChord(.escape)),
        .pushToTalk: .chord(KeyChord(.l, [.command, .shift])),
        .pasteLast: .chord(KeyChord(.v, [.command, .shift])),
      ])
    } catch {
      fatalError("Chord fixture is invalid: \(error)")
    }
  }()
}

extension KeyEvent {
  /// A flags change holding the left side of each modifier, as most tests written before one-key holds assume.
  static func flags(_ modifiers: Modifiers) -> KeyEvent {
    .modifiersChanged(
      HeldKeys(ModifierKey.allCases.filter { modifiers.contains($0.modifiers) }.map { HeldKeys($0.left) }))
  }
}
