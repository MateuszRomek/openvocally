import Testing

@testable import Hotkeys

/// Raw flag bits as CGEventFlags / NSEvent.ModifierFlags carry them.
private let maskCommand: UInt64 = 0x10_0000
private let maskAlternate: UInt64 = 0x8_0000
private let maskAlphaShift: UInt64 = 0x1_0000
private let maskSecondaryFn: UInt64 = 0x80_0000

struct HeldKeysParsingTests {
  private func flags(_ raw: UInt64, _ key: UInt16?) -> HeldKeys {
    HeldKeys(rawFlags: raw, changedKey: key.map(KeyCode.init(rawValue:)), isFlagsChange: true)
  }

  @Test func `right command from its device bit`() {
    let held = flags(maskCommand | 0x10, 54)
    #expect(held == HeldKeys(.rightCommand))
    #expect(held.modifiers == [.command])
  }

  @Test func `left command from its device bit`() {
    #expect(flags(maskCommand | 0x08, 55) == HeldKeys(.leftCommand))
  }

  @Test func `both sides held`() {
    let held = flags(maskCommand | 0x08 | 0x10, 54)
    #expect(held == HeldKeys([HeldKeys(.leftCommand), HeldKeys(.rightCommand)]))
    #expect(held.only == nil)
    #expect(held.modifiers == [.command])
  }

  @Test func `releasing one side keeps the other`() {
    #expect(flags(maskCommand | 0x08, 54) == HeldKeys(.leftCommand))
  }

  @Test func `no device bit takes the changed key's side`() {
    #expect(flags(maskCommand, 54) == HeldKeys(.rightCommand))
  }

  @Test func `no device bit and no key falls back to left`() {
    #expect(flags(maskCommand, nil) == HeldKeys(.leftCommand))
  }

  @Test func `no device bit and another family's key falls back to left`() {
    #expect(
      flags(maskCommand | maskAlternate | 0x40, 61)
        == HeldKeys([HeldKeys(.leftCommand), HeldKeys(.rightOption)]))
  }

  @Test func `fn on a flags change`() {
    let held = flags(maskSecondaryFn, 63)
    #expect(held == HeldKeys(.fn))
    #expect(held.only == .fn)
    #expect(held.modifiers == [])
  }

  @Test func `fn bit on an arrow key-down is ignored`() {
    #expect(
      KeyEvent(.keyDown, keyCode: KeyCode(rawValue: 123), rawFlags: maskSecondaryFn, isAutorepeat: false)
        == .down(KeyCode(rawValue: 123), []))
  }

  @Test(arguments: HoldKey.allCases)
  func `every side round trips`(key: HoldKey) {
    let generic = key.family?.flagMask ?? 0
    #expect(flags(generic | key.deviceMask, key.keyCode.rawValue) == HeldKeys(key))
    #expect(HoldKey(keyCode: key.keyCode) == key)
  }

  @Test func `caps lock alone is empty`() {
    #expect(flags(maskAlphaShift, 57) == [])
  }

  @Test func `a key-down projects device bits to sideless modifiers`() {
    #expect(
      KeyEvent(.keyDown, keyCode: .space, rawFlags: maskCommand | 0x10, isAutorepeat: true)
        == .down(.space, [.command], isAutorepeat: true))
    #expect(
      KeyEvent(.keyUp, keyCode: .space, rawFlags: maskAlternate | 0x40, isAutorepeat: false)
        == .up(.space, [.option]))
    #expect(
      KeyEvent(.pointerDown, keyCode: .space, rawFlags: maskCommand, isAutorepeat: false) == .pointerDown)
  }

  @Test func `keys are ordered for the key caps`() {
    let held = HeldKeys([HeldKeys(.fn), HeldKeys(.rightCommand), HeldKeys(.leftControl)])
    #expect(held.keys == [.leftControl, .rightCommand, .fn])
  }

  @Test func `modifier keycodes derive from the hold key table`() {
    #expect(ModifierKey.command.leftKeyCode == KeyCode(rawValue: 55))
    #expect(ModifierKey.command.rightKeyCode == KeyCode(rawValue: 54))
    #expect(ModifierKey(keyCode: KeyCode(rawValue: 61)) == .option)
    #expect(ModifierKey(keyCode: KeyCode(rawValue: 63)) == nil)
  }

  @Test func `labels`() {
    #expect(HoldKey.rightCommand.label == "Right ⌘")
    #expect(HoldKey.leftOption.name == "Left Option")
    #expect(HotkeyTrigger.hold(.fn).label == "Fn")
    #expect(HotkeyTrigger.hold(.rightCommand).accessibilityDescription == "Hold Right Command")
  }
}
