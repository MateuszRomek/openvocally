import Foundation
import Testing

@testable import Hotkeys

private func chord(_ key: KeyCode, _ modifiers: Modifiers = []) -> HotkeyTrigger {
  .chord(KeyChord(key, modifiers))
}

struct HotkeyBindingsTests {
  @Test func defaultsOptionDToToggle() {
    let defaults = HotkeyBindings.defaults
    #expect(defaults.trigger(for: .toggle) == chord(.d, [.option]))
    #expect(defaults.trigger(for: .cancel) == chord(.escape))
    #expect(defaults.trigger(for: .pushToTalk) == chord(.space, [.option]))
    #expect(defaults.trigger(for: .pasteLast) == chord(.v, [.control, .option]))
  }

  @Test func defaultsPassValidation() throws {
    #expect(try HotkeyBindings(HotkeyBindings.defaults.triggers) == .defaults)
  }

  @Test func duplicateChordIsRejected() {
    let trigger = chord(.l, [.command, .shift])
    #expect(throws: HotkeyBindings.Invalid.duplicate(trigger, owner: .pushToTalk)) {
      try HotkeyBindings([.pushToTalk: trigger, .pasteLast: trigger])
    }
  }

  @Test func duplicateDoubleTapIsRejected() throws {
    let bindings = try HotkeyBindings([.toggle: .doubleTap(.option)])
    #expect(throws: HotkeyBindings.Invalid.duplicate(.doubleTap(.option), owner: .toggle)) {
      try bindings.replacing(.pasteLast, with: .doubleTap(.option))
    }
  }

  @Test func doubleTapsOfDifferentModifiersCoexist() throws {
    let bindings = try HotkeyBindings([.toggle: .doubleTap(.option), .pasteLast: .doubleTap(.command)])
    #expect(bindings.trigger(for: .pasteLast) == .doubleTap(.command))
  }

  @Test(arguments: ModifierKey.allCases)
  func doubleTapCannotDrivePushToTalk(key: ModifierKey) {
    #expect(throws: HotkeyBindings.Invalid.cannotHold(.doubleTap(key))) {
      try HotkeyBindings([.pushToTalk: .doubleTap(key)])
    }
    #expect(throws: HotkeyBindings.Invalid.cannotHold(.doubleTap(key))) {
      try HotkeyBindings([:]).replacing(.pushToTalk, with: .doubleTap(key))
    }
  }

  @Test(arguments: [HotkeyAction.cancel, .toggle], [Modifiers(), .command])
  func chordOnAModifierKeyIsRejected(action: HotkeyAction, modifiers: Modifiers) {
    let leftOption = KeyChord(KeyCode(rawValue: 58), modifiers)
    #expect(throws: HotkeyBindings.Invalid.unsafe(leftOption)) {
      try HotkeyBindings([action: .chord(leftOption)])
    }
    #expect(throws: HotkeyBindings.Invalid.unsafe(leftOption)) {
      try HotkeyBindings([:]).replacing(action, with: .chord(leftOption))
    }
  }

  @Test(arguments: ModifierKey.allCases)
  func everyDoubleTapIsSafeForToggle(key: ModifierKey) throws {
    #expect(try HotkeyBindings([.toggle: .doubleTap(key)]).trigger(for: .toggle) == .doubleTap(key))
  }

  @Test func sameKeyWithDifferentModifiersIsAllowed() throws {
    let bindings = try HotkeyBindings([
      .pushToTalk: chord(.l, [.command, .shift]),
      .pasteLast: chord(.l, [.command]),
    ])
    #expect(bindings.trigger(for: .pasteLast) == chord(.l, [.command]))
  }

  @Test func replacingWithATriggerOwnedByAnotherActionThrows() {
    #expect(throws: HotkeyBindings.Invalid.duplicate(chord(.escape), owner: .cancel)) {
      try HotkeyBindings.defaults.replacing(.toggle, with: chord(.escape))
    }
  }

  @Test func replacingAnActionWithItsOwnTriggerChangesNothing() throws {
    let same = try HotkeyBindings.defaults.replacing(.toggle, with: chord(.d, [.option]))
    #expect(same == .defaults)
  }

  @Test func replacingFreesTheOldTrigger() throws {
    let trigger = chord(KeyCode(rawValue: 40), [.command, .option])
    let next = try HotkeyBindings.defaults.replacing(.toggle, with: trigger)
    #expect(next.trigger(for: .toggle) == trigger)
    #expect(next.actionByTrigger[chord(.d, [.option])] == nil)
    #expect(next.trigger(for: .cancel) == chord(.escape))
  }

  @Test func unboundActionHasNoTrigger() throws {
    let bindings = try HotkeyBindings([.toggle: chord(.space, [.command])])
    #expect(bindings.trigger(for: .cancel) == nil)
  }

  @Test func chordWithoutCommandControlOrOptionIsRejected() {
    for keyChord in [KeyChord(.l), KeyChord(.l, [.shift])] {
      #expect(throws: HotkeyBindings.Invalid.unsafe(keyChord)) {
        try HotkeyBindings([.pushToTalk: .chord(keyChord)])
      }
      #expect(throws: HotkeyBindings.Invalid.unsafe(keyChord)) {
        try HotkeyBindings.defaults.replacing(.pushToTalk, with: .chord(keyChord))
      }
    }
  }

  @Test func cancelAndFunctionKeysMayBeBare() throws {
    let f13 = chord(KeyCode(rawValue: 105))
    let bindings = try HotkeyBindings([.cancel: chord(.escape), .toggle: f13])
    #expect(bindings.trigger(for: .toggle) == f13)
    #expect(
      try HotkeyBindings.defaults.replacing(.cancel, with: chord(.l)).trigger(for: .cancel) == chord(.l))
  }

  @Test func commandVIsRejectedForEveryAction() {
    let commandV = KeyChord(.v, [.command])
    for action in HotkeyAction.allCases {
      #expect(throws: HotkeyBindings.Invalid.unsafe(commandV)) {
        try HotkeyBindings([action: .chord(commandV)])
      }
      #expect(throws: HotkeyBindings.Invalid.unsafe(commandV)) {
        try HotkeyBindings.defaults.replacing(action, with: .chord(commandV))
      }
    }
  }
}
