/// One of the four modifiers that can be double-tapped on its own.
public enum ModifierKey: CaseIterable, Hashable, Sendable {
  case command, control, option, shift

  /// The single flag this key sets.
  public var modifiers: Modifiers {
    switch self {
    case .command: .command
    case .control: .control
    case .option: .option
    case .shift: .shift
    }
  }

  /// `nil` unless `modifiers` is exactly one flag.
  public init?(_ modifiers: Modifiers) {
    guard let key = Self.allCases.first(where: { $0.modifiers == modifiers }) else { return nil }
    self = key
  }

  public var symbol: String { modifiers.symbols }

  public var name: String {
    switch self {
    case .command: "Command"
    case .control: "Control"
    case .option: "Option"
    case .shift: "Shift"
    }
  }

  /// The left key's ANSI keycode. Storage writes a double tap as this keycode with no modifiers.
  public var leftKeyCode: KeyCode { left.keyCode }

  var rightKeyCode: KeyCode { right.keyCode }

  /// Either side's keycode.
  public init?(keyCode: KeyCode) {
    guard let key = HoldKey(keyCode: keyCode)?.family else { return nil }
    self = key
  }
}

/// What the user presses to fire an action: a key chord, a double tap of one modifier, or
/// one key held alone.
public enum HotkeyTrigger: Hashable, Sendable {
  case chord(KeyChord)
  case doubleTap(ModifierKey)
  /// Hold one key alone. Push to talk only.
  case hold(HoldKey)

  /// Such as "⇧⌘Space" or "⌥⌥".
  public var label: String {
    switch self {
    case .chord(let chord): chord.label
    case .doubleTap(let key): key.symbol + key.symbol
    case .hold(let key): key.label
    }
  }

  /// One label per physical key, such as ["⇧", "⌘", "Space"] or ["⌥", "⌥"], for drawing
  /// each key as its own cap.
  public var keyCaps: [String] {
    switch self {
    case .chord(let chord): chord.modifiers.symbols.map(String.init) + [chord.keyLabel]
    case .doubleTap(let key): [key.symbol, key.symbol]
    case .hold(let key): [key.label]
    }
  }

  /// Such as "Double-tap Option". A chord reads as its label.
  public var accessibilityDescription: String {
    switch self {
    case .chord(let chord): chord.label
    case .doubleTap(let key): "Double-tap \(key.name)"
    case .hold(let key): "Hold \(key.name)"
    }
  }
}
