/// Physical key (ANSI virtual keycode). Layout-independent, so a binding names the same key on every layout.
public struct KeyCode: Hashable, Sendable {
  public let rawValue: UInt16

  public init(rawValue: UInt16) {
    self.rawValue = rawValue
  }

  public static let space = KeyCode(rawValue: 49)
  public static let escape = KeyCode(rawValue: 53)
  static let d = KeyCode(rawValue: 2)
  public static let l = KeyCode(rawValue: 37)
  public static let v = KeyCode(rawValue: 9)

  /// F1 to F20, in order. They type nothing, so they may be bound without a modifier.
  static let functionKeys: [KeyCode] =
    [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    .map(KeyCode.init(rawValue:))
}

/// The only four modifiers that take part in matching. Left and right are not
/// distinguished, and Fn, Caps Lock and the numeric-pad flag are not representable,
/// so they cannot leak into a comparison.
public struct Modifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let command = Modifiers(rawValue: 1 << 0)
  public static let control = Modifiers(rawValue: 1 << 1)
  public static let option = Modifiers(rawValue: 1 << 2)
  static let shift = Modifiers(rawValue: 1 << 3)

  /// Stored bindings are untrusted input; an undefined bit would make a chord nothing can press.
  public init?(validating rawValue: Int) {
    guard let byte = UInt8(exactly: rawValue), byte & ~Modifiers.all.rawValue == 0 else { return nil }
    self.init(rawValue: byte)
  }

  private static let all: Modifiers = [.command, .control, .option, .shift]
}

public struct KeyChord: Hashable, Sendable {
  public let key: KeyCode
  public let modifiers: Modifiers

  public init(_ key: KeyCode, _ modifiers: Modifiers = []) {
    self.key = key
    self.modifiers = modifiers
  }

  /// The system paste chord. Bindings can never take it, because the app's own synthetic
  /// paste goes through the same tap.
  public static let paste = KeyChord(.v, [.command])
}
