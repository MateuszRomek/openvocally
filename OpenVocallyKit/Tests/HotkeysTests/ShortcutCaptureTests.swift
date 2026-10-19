import Testing

@testable import Hotkeys

struct ShortcutCaptureTests {
  @Test func defaultsReadAsMacMenusDrawThem() {
    let defaults = HotkeyBindings.defaults
    #expect(defaults.trigger(for: .toggle)?.label == "⌥D")
    #expect(defaults.trigger(for: .cancel)?.label == "Esc")
    #expect(defaults.trigger(for: .pushToTalk)?.label == "⌥Space")
    #expect(defaults.trigger(for: .pasteLast)?.label == "⌃⌥V")
  }

  @Test func doubleTapReadsAsASpokenGesture() {
    #expect(HotkeyTrigger.doubleTap(.option).accessibilityDescription == "Double-tap Option")
    #expect(HotkeyTrigger.doubleTap(.command).label == "⌘⌘")
  }

  @Test func modifiersFollowControlOptionShiftCommand() {
    #expect(KeyChord(.space, [.command, .shift, .option, .control]).label == "⌃⌥⇧⌘Space")
  }

  @Test func eachKeyGetsItsOwnCap() {
    #expect(HotkeyTrigger.chord(KeyChord(.space, [.command, .shift])).keyCaps == ["⇧", "⌘", "Space"])
    #expect(HotkeyTrigger.doubleTap(.option).keyCaps == ["⌥", "⌥"])
    #expect(HotkeyTrigger.hold(.rightCommand).keyCaps == ["Right ⌘"])
  }

  @Test func everyFunctionKeyHasALabel() {
    let labels = Set(KeyCode.functionKeys.compactMap(\.label))
    #expect(labels == Set((1...20).map { "F\($0)" }))
  }

  @Test func bareEscapeCancelsRecording() {
    #expect(ShortcutCapture(key: .escape, modifiers: [], isRepeat: false, recording: .toggle) == .cancel)
  }

  @Test func bareEscapeRecordsOnTheCancelRow() {
    #expect(
      ShortcutCapture(key: .escape, modifiers: [], isRepeat: false, recording: .cancel)
        == .record(KeyChord(.escape)))
  }

  @Test func escapeWithAModifierRecords() {
    #expect(
      ShortcutCapture(key: .escape, modifiers: [.option], isRepeat: false, recording: .toggle)
        == .record(KeyChord(.escape, [.option])))
  }

  @Test func autorepeatIsIgnored() {
    #expect(ShortcutCapture(key: .l, modifiers: [.command], isRepeat: true, recording: .toggle) == .ignore)
  }

  @Test func keypadKeyIsUnsupported() {
    let keypadEnter = KeyCode(rawValue: 76)
    #expect(
      ShortcutCapture(key: keypadEnter, modifiers: [.command], isRepeat: false, recording: .toggle)
        == .unsupportedKey)
  }

  @Test func availabilityFollowsTheStartError() {
    #expect(HotkeyAvailability(.accessibilityNotGranted) == .needsAccessibility)
    #expect(HotkeyAvailability(.tapCreationFailed) == .failed)
  }
}
