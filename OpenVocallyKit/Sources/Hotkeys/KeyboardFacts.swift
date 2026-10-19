import Carbon
import Foundation

/// Reads the live facts `HoldKeyRisk` judges. Main actor: TIS calls are main-thread only.
@MainActor public enum KeyboardFacts {
  /// The 26 ANSI letter keycodes, A to Z.
  private static let letterKeyCodes: [UInt16] = [
    0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
  ]

  static func optionLayer() -> OptionLayer {
    let empty = OptionLayer(language: nil, base: [], option: [])
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return empty }
    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
    var language: String?
    if let rawLanguages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
      let languages = Unmanaged<CFArray>.fromOpaque(rawLanguages).takeUnretainedValue() as? [String]
      language = languages?.first
    }
    let optionState = UInt32((optionKey >> 8) & 0xFF)
    var base: Set<Character> = []
    var option: Set<Character> = []
    layoutData.withUnsafeBytes { buffer in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
      for code in letterKeyCodes {
        if let character = translate(layout, code, modifiers: 0) { base.insert(character) }
        if let character = translate(layout, code, modifiers: optionState) { option.insert(character) }
      }
    }
    return OptionLayer(language: language, base: base, option: option)
  }

  /// One key press through the layout. A dead key (its state is left non-zero) types nothing
  /// on its own, so it is dropped.
  private static func translate(
    _ layout: UnsafePointer<UCKeyboardLayout>, _ keyCode: UInt16, modifiers: UInt32
  ) -> Character? {
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(
      layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), 0, &deadKeyState,
      characters.count, &length, &characters)
    guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
    let text = String(utf16CodeUnits: characters, count: length)
    return text.count == 1 ? text.first : nil
  }

  static func fnUsage() -> FnUsage {
    FnUsage(
      storedValue: UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int)
  }

  /// The letters of `language` among `candidates`, from its Locale exemplar set. Empty when unknown.
  public static func letters(of language: String?, among candidates: Set<Character>) -> Set<Character> {
    guard let language,
      let exemplar = (Locale(identifier: language) as NSLocale).object(forKey: .exemplarCharacterSet)
        as? CharacterSet
    else { return [] }
    return candidates.filter { character in
      character.lowercased().unicodeScalars.allSatisfy { exemplar.contains($0) }
    }
  }

  public static func warning(for key: HoldKey) -> HoldKeyWarning? {
    let layer = optionLayer()
    return HoldKeyRisk.warning(
      for: key, layer: layer, letters: letters(of: layer.language, among: layer.option), fnUsage: fnUsage())
  }
}
