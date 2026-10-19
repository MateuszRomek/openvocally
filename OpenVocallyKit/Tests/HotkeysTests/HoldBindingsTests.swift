import Testing

@testable import Hotkeys

struct HoldBindingsTests {
  @Test(arguments: [HotkeyAction.toggle, .cancel, .pasteLast])
  func `a hold is push to talk only`(action: HotkeyAction) {
    #expect(throws: HotkeyBindings.Invalid.holdIsPushToTalkOnly(.hold(.rightCommand))) {
      try HotkeyBindings.defaults.replacing(action, with: .hold(.rightCommand))
    }
  }

  @Test func `a hold is accepted for push to talk`() throws {
    let bindings = try HotkeyBindings.defaults.replacing(.pushToTalk, with: .hold(.rightCommand))
    #expect(bindings.trigger(for: .pushToTalk) == .hold(.rightCommand))
  }

  @Test func `a hold overlaps a double tap of the same family, in both orders`() throws {
    let withDoubleTap = try HotkeyBindings.defaults.replacing(.toggle, with: .doubleTap(.command))
    #expect(throws: HotkeyBindings.Invalid.overlaps(.hold(.rightCommand), owner: .toggle)) {
      try withDoubleTap.replacing(.pushToTalk, with: .hold(.rightCommand))
    }
    let withHold = try HotkeyBindings.defaults.replacing(.pushToTalk, with: .hold(.rightCommand))
    #expect(throws: HotkeyBindings.Invalid.overlaps(.doubleTap(.command), owner: .pushToTalk)) {
      try withHold.replacing(.toggle, with: .doubleTap(.command))
    }
    #expect(throws: HotkeyBindings.Invalid.overlaps(.hold(.leftCommand), owner: .toggle)) {
      try HotkeyBindings([.toggle: .doubleTap(.command), .pushToTalk: .hold(.leftCommand)])
    }
  }

  @Test func `a hold and a double tap of another family are fine`() throws {
    let bindings = try HotkeyBindings([.toggle: .doubleTap(.option), .pushToTalk: .hold(.rightCommand)])
    #expect(bindings.trigger(for: .toggle) == .doubleTap(.option))
  }

  @Test(arguments: ModifierKey.allCases)
  func `an fn hold has no family overlap`(family: ModifierKey) throws {
    let bindings = try HotkeyBindings([.toggle: .doubleTap(family), .pushToTalk: .hold(.fn)])
    #expect(bindings.trigger(for: .pushToTalk) == .hold(.fn))
  }

  @Test func `defaults keep option space`() {
    #expect(HotkeyBindings.defaults.trigger(for: .pushToTalk) == .chord(KeyChord(.space, [.option])))
  }

  @Test func `rebind maps the new errors`() {
    let hotkeys = Hotkeys(bindings: .defaults)
    #expect(throws: RebindError.invalid(.holdIsPushToTalkOnly(.hold(.rightCommand)))) {
      try hotkeys.rebind(.toggle, to: .hold(.rightCommand)) { _ in }
    }
    let withDoubleTap = Hotkeys(
      bindings: (try? HotkeyBindings.defaults.replacing(.toggle, with: .doubleTap(.command))) ?? .defaults)
    #expect(throws: RebindError.invalid(.overlaps(.hold(.rightCommand), owner: .toggle))) {
      try withDoubleTap.rebind(.pushToTalk, to: .hold(.rightCommand)) { _ in }
    }
  }
}
