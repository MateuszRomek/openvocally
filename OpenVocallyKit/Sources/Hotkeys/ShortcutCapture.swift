/// What one key-down means to the shortcut recorder in Settings. Modifier presses
/// arrive as flag changes, not key-downs, so the recorder keeps listening through them.
enum ShortcutCapture: Equatable, Sendable {
  /// Bare Escape stops recording, except on the cancel row, where Escape is the default.
  case cancel
  case record(KeyChord)
  /// A key with no label, such as the keypad or a media key.
  case unsupportedKey
  /// Autorepeat of a key already handled.
  case ignore

  init(key: KeyCode, modifiers: Modifiers, isRepeat: Bool, recording action: HotkeyAction) {
    if isRepeat {
      self = .ignore
    } else if key == .escape, modifiers.isEmpty, action != .cancel {
      self = .cancel
    } else if key.label == nil {
      self = .unsupportedKey
    } else {
      self = .record(KeyChord(key, modifiers))
    }
  }
}
