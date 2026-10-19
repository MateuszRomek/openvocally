import Testing

@testable import Hotkeys

private let commandOptionK = HotkeyTrigger.chord(KeyChord(KeyCode(rawValue: 40), [.command, .option]))

struct HotkeyLoadingTests {
  @Test func nothingStoredLoadsDefaults() {
    #expect(HotkeyBindings.loading(stored: [:]) == .defaults)
  }

  @Test func storedDuplicateLoadsDefaults() {
    #expect(
      HotkeyBindings.loading(stored: ["toggle": commandOptionK, "pasteLast": commandOptionK]) == .defaults)
  }

  @Test func storedUnsafeChordLoadsDefaults() {
    #expect(HotkeyBindings.loading(stored: ["toggle": .chord(KeyChord(.v, [.command]))]) == .defaults)
  }

  @Test func storedPushToTalkDoubleTapLoadsDefaults() {
    #expect(HotkeyBindings.loading(stored: ["pushToTalk": .doubleTap(.shift)]) == .defaults)
  }

  @Test func unknownActionNamesAreIgnored() {
    let loaded = HotkeyBindings.loading(stored: [
      "toggle": commandOptionK, "teleport": .chord(KeyChord(.space, [.control])),
    ])
    #expect(loaded.trigger(for: .toggle) == commandOptionK)
    #expect(loaded.trigger(for: .pushToTalk) == .chord(KeyChord(.space, [.option])))
  }

  @Test func storedTriggerEqualToAMissingActionsDefaultKeepsTheStoredOne() {
    let loaded = HotkeyBindings.loading(stored: ["pasteLast": .chord(KeyChord(.d, [.option]))])
    #expect(loaded.trigger(for: .pasteLast) == .chord(KeyChord(.d, [.option])))
    #expect(loaded.trigger(for: .toggle) == nil)
    #expect(loaded.trigger(for: .cancel) == .chord(KeyChord(.escape)))
  }

  @Test func missingActionTakesItsDefault() {
    let loaded = HotkeyBindings.loading(stored: ["toggle": commandOptionK])
    #expect(loaded.trigger(for: .toggle) == commandOptionK)
    #expect(loaded.trigger(for: .cancel) == .chord(KeyChord(.escape)))
    #expect(loaded.trigger(for: .pushToTalk) == .chord(KeyChord(.space, [.option])))
    #expect(loaded.trigger(for: .pasteLast) == .chord(KeyChord(.v, [.control, .option])))
  }

  @Test func undefinedModifierBitsAreRejected() {
    #expect(Modifiers(validating: 0b1_0000) == nil)
    #expect(Modifiers(validating: 256) == nil)
    #expect(Modifiers(validating: 0b1001) == [.command, .shift])
  }
}
