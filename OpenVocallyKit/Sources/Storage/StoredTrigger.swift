import Hotkeys

/// The `shortcut_bindings` row encoding, in one place.
///   chord:      (key code, Modifiers.rawValue in 0...15)
///   double tap: (left keycode of the family, 0)
///   hold:       (HoldKey.keyCode, 0x80)
/// 0x80 is outside every Modifiers bit, so no chord or double-tap row can collide, and the
/// UNIQUE(key_code, modifiers) constraint keeps holding. No migration. An older build reads
/// a hold row as unusable and loads the defaults in memory without writing, so the row
/// survives a downgrade until the user rebinds there.
enum StoredTrigger {
  static let holdMarker = 0x80

  static func columns(_ trigger: HotkeyTrigger) -> (keyCode: Int, modifiers: Int) {
    switch trigger {
    case .chord(let chord): (Int(chord.key.rawValue), Int(chord.modifiers.rawValue))
    case .doubleTap(let modifier): (Int(modifier.leftKeyCode.rawValue), 0)
    case .hold(let key): (Int(key.keyCode.rawValue), holdMarker)
    }
  }

  /// nil for a row no trigger can come from. A double tap is stored as its modifier's keycode
  /// with no modifiers: a modifier key never arrives as a key-down, and a chord with no
  /// Command, Control or Option is rejected, so no chord row looks like one.
  static func trigger(keyCode: Int64, modifiers: Int64) -> HotkeyTrigger? {
    guard let rawKey = UInt16(exactly: keyCode) else { return nil }
    let key = KeyCode(rawValue: rawKey)
    if modifiers == Int64(holdMarker) { return HoldKey(keyCode: key).map(HotkeyTrigger.hold) }
    guard let modifiers = Modifiers(validating: Int(clamping: modifiers)) else { return nil }
    if modifiers.isEmpty, let modifier = ModifierKey(keyCode: key) { return .doubleTap(modifier) }
    return .chord(KeyChord(key, modifiers))
  }
}
