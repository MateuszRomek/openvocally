import CoreGraphics
import Testing

@testable import Hotkeys

struct KeyEventTranslationTests {
  @Test func extraFlagsAreIgnored() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true))
    event.flags = [.maskCommand, .maskShift, .maskSecondaryFn, .maskAlphaShift, .maskNumericPad]
    let keyEvent = KeyEvent(event, .keyDown)
    #expect(keyEvent == .down(.l, [.command, .shift]))
    var matcher = HotkeyMatcher(bindings: .chordFixture)
    #expect(matcher.handle(keyEvent) == Verdict(.consume, emit: .pushToTalkStart))
  }

  @Test func allFourModifiersAndAutorepeatAreRead() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
    event.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    #expect(
      KeyEvent(event, .keyDown) == .down(.space, [.command, .control, .option, .shift], isAutorepeat: true))
  }

  @Test func keyUpTranslates() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
    event.flags = []  // a nil source copies the live modifier state
    #expect(KeyEvent(event, .keyUp) == .up(.escape, []))
  }

  @Test func flagsChangedTranslatesToTheHeldModifiers() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true))
    event.flags = [.maskAlternate, .maskSecondaryFn]
    #expect(KeyEvent(event, .flagsChanged) == .modifiersChanged([HeldKeys(.leftOption), HeldKeys(.fn)]))
  }

  @Test(arguments: [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
  func mouseDownTranslatesToPointerDown(type: CGEventType) throws {
    let event = try #require(
      CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left))
    event.flags = [.maskAlternate]
    #expect(KeyEvent(event, type) == .pointerDown)
  }
}
