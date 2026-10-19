import Testing

@testable import Hotkeys

private let latin: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz")
private let polishLetters: Set<Character> = latin.union("ąćęłńóśźż")
private let quiet = OptionLayer(language: "en", base: latin, option: [])

struct HoldKeyRiskTests {
  @Test func `polish option warns`() {
    let layer = OptionLayer(language: "pl", base: latin, option: Set("ąćęłńóśźż©™"))
    let warning = HoldKeyRisk.warning(
      for: .rightOption, layer: layer, letters: polishLetters, fnUsage: .doNothing)
    #expect(warning == .optionTypesLetters(.rightOption, language: "Polish", examples: ["ó", "ą", "ć"]))
  }

  @Test func `us option is quiet`() {
    let layer = OptionLayer(language: "en", base: latin, option: Set("åßçø∂ƒ©˙∆˚¬µ"))
    #expect(HoldKeyRisk.warning(for: .leftOption, layer: layer, letters: latin, fnUsage: .doNothing) == nil)
  }

  @Test func `german option is quiet`() {
    let base = latin.union("äöü")
    let layer = OptionLayer(language: "de", base: base, option: Set("@€äöü"))
    #expect(HoldKeyRisk.warning(for: .rightOption, layer: layer, letters: base, fnUsage: .doNothing) == nil)
  }

  @Test(arguments: [FnUsage.changeInputSource, .showEmoji, .startDictation, .systemDefault])
  func `fn warns unless it does nothing`(usage: FnUsage) {
    #expect(
      HoldKeyRisk.warning(for: .fn, layer: quiet, letters: latin, fnUsage: usage) == .fnHasSystemAction(usage)
    )
  }

  @Test func `fn doing nothing is quiet`() {
    #expect(HoldKeyRisk.warning(for: .fn, layer: quiet, letters: latin, fnUsage: .doNothing) == nil)
  }

  @Test func `fn usage parsing`() {
    #expect(FnUsage(storedValue: nil) == .systemDefault)
    #expect(FnUsage(storedValue: 0) == .doNothing)
    #expect(FnUsage(storedValue: 1) == .changeInputSource)
    #expect(FnUsage(storedValue: 2) == .showEmoji)
    #expect(FnUsage(storedValue: 3) == .startDictation)
    #expect(FnUsage(storedValue: 7) == .systemDefault)
  }

  @Test func `shift and the left shortcut keys warn, right command and control are quiet`() {
    #expect(
      HoldKeyRisk.warning(for: .rightShift, layer: quiet, letters: latin, fnUsage: .doNothing)
        == .shiftTypesCapitals(.rightShift))
    #expect(
      HoldKeyRisk.warning(for: .leftCommand, layer: quiet, letters: latin, fnUsage: .doNothing)
        == .usedForShortcuts(.leftCommand))
    #expect(
      HoldKeyRisk.warning(for: .leftControl, layer: quiet, letters: latin, fnUsage: .doNothing)
        == .usedForShortcuts(.leftControl))
    #expect(HoldKeyRisk.warning(for: .rightCommand, layer: quiet, letters: latin, fnUsage: .showEmoji) == nil)
    #expect(HoldKeyRisk.warning(for: .rightControl, layer: quiet, letters: latin, fnUsage: .showEmoji) == nil)
    #expect(
      HoldKeyWarning.usedForShortcuts(.leftCommand).message
        == "Most shortcuts use Left ⌘, so the mic would open briefly with each one. Right ⌘ is rarely used.")
  }

  @Test func `message copy`() {
    #expect(
      HoldKeyWarning.optionTypesLetters(.rightOption, language: "Polish", examples: ["ą"]).message
        == "Right ⌥ types Polish letters. You'd start recording while typing.")
    #expect(
      HoldKeyWarning.fnHasSystemAction(.showEmoji).message
        == "macOS uses Fn to show emoji. Set Globe key to Do Nothing in Keyboard settings.")
  }
}
