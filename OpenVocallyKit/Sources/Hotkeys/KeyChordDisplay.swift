extension KeyCode {
  /// The key's label in Settings, by ANSI position like the matcher. `nil` for keys the
  /// recorder does not accept, such as the keypad and media keys.
  public var label: String? {
    Self.labels[rawValue]
  }

  private static let labels: [UInt16: String] = {
    var labels: [UInt16: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
      12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
      22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
      32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
      43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
      36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
      115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
      123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    for (index, code) in KeyCode.functionKeys.enumerated() { labels[code.rawValue] = "F\(index + 1)" }
    return labels
  }()
}

extension Modifiers {
  /// In the order macOS menus draw them: Control, Option, Shift, Command.
  var symbols: String {
    var symbols = ""
    if contains(.control) { symbols += "⌃" }
    if contains(.option) { symbols += "⌥" }
    if contains(.shift) { symbols += "⇧" }
    if contains(.command) { symbols += "⌘" }
    return symbols
  }
}

extension KeyChord {
  /// Such as "⇧⌘Space". A key with no label shows its code, which only a hand-edited
  /// database can produce.
  public var label: String {
    modifiers.symbols + keyLabel
  }

  var keyLabel: String { key.label ?? "Key \(key.rawValue)" }
}
