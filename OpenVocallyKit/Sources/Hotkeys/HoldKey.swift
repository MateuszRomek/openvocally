/// One physical key that can be held alone to talk: a sided modifier or Fn / Globe.
/// `ModifierKey` stays the sideless family that double tap matches on. This is the single
/// table of sided keycodes; `ModifierKey` derives its left and right keycodes from it.
public enum HoldKey: CaseIterable, Hashable, Sendable {
  case leftCommand, rightCommand
  case leftOption, rightOption
  case leftControl, rightControl
  case leftShift, rightShift
  case fn

  /// The ANSI keycode a flagsChanged event carries for this key. Storage writes it too.
  public var keyCode: KeyCode {
    switch self {
    case .leftCommand: KeyCode(rawValue: 55)
    case .rightCommand: KeyCode(rawValue: 54)
    case .leftOption: KeyCode(rawValue: 58)
    case .rightOption: KeyCode(rawValue: 61)
    case .leftControl: KeyCode(rawValue: 59)
    case .rightControl: KeyCode(rawValue: 62)
    case .leftShift: KeyCode(rawValue: 56)
    case .rightShift: KeyCode(rawValue: 60)
    case .fn: KeyCode(rawValue: 63)
    }
  }

  public init?(keyCode: KeyCode) {
    guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
    self = key
  }

  /// nil for Fn, which is not one of the four matching modifiers.
  var family: ModifierKey? {
    switch self {
    case .leftCommand, .rightCommand: .command
    case .leftOption, .rightOption: .option
    case .leftControl, .rightControl: .control
    case .leftShift, .rightShift: .shift
    case .fn: nil
    }
  }

  var isRight: Bool {
    switch self {
    case .rightCommand, .rightOption, .rightControl, .rightShift: true
    default: false
    }
  }

  /// Such as "Right ⌘" or "Fn". The key cap and the setup card read this.
  public var label: String {
    guard let family else { return "Fn" }
    return (isRight ? "Right " : "Left ") + family.symbol
  }

  /// Such as "Right Command". VoiceOver reads this.
  public var name: String {
    guard let family else { return "Fn" }
    return (isRight ? "Right " : "Left ") + family.name
  }

  /// The IOKit NX_DEVICE* bit for this side, or NX_SECONDARYFNMASK for Fn.
  var deviceMask: UInt64 {
    switch self {
    case .leftControl: 0x1
    case .leftShift: 0x2
    case .rightShift: 0x4
    case .leftCommand: 0x8
    case .rightCommand: 0x10
    case .leftOption: 0x20
    case .rightOption: 0x40
    case .rightControl: 0x2000
    case .fn: HeldKeys.secondaryFnMask
    }
  }

  /// Its position in `allCases`, as a switch so the tap thread never builds that array.
  fileprivate var bit: UInt16 {
    switch self {
    case .leftCommand: 1 << 0
    case .rightCommand: 1 << 1
    case .leftOption: 1 << 2
    case .rightOption: 1 << 3
    case .leftControl: 1 << 4
    case .rightControl: 1 << 5
    case .leftShift: 1 << 6
    case .rightShift: 1 << 7
    case .fn: 1 << 8
    }
  }
}

extension ModifierKey {
  public var left: HoldKey {
    switch self {
    case .command: .leftCommand
    case .option: .leftOption
    case .control: .leftControl
    case .shift: .leftShift
    }
  }

  public var right: HoldKey {
    switch self {
    case .command: .rightCommand
    case .option: .rightOption
    case .control: .rightControl
    case .shift: .rightShift
    }
  }

  /// The generic device-independent flag (CGEventFlags / NSEvent.ModifierFlags raw value).
  var flagMask: UInt64 {
    switch self {
    case .shift: 0x20000
    case .control: 0x40000
    case .option: 0x80000
    case .command: 0x100000
    }
  }
}

/// Every hold key down right now, by side. The only place sides exist; `modifiers` projects
/// them onto the four sideless flags that chords and double tap match on.
public struct HeldKeys: OptionSet, Hashable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public init(_ key: HoldKey) { self.init(rawValue: key.bit) }

  /// maskSecondaryFn.
  static let secondaryFnMask: UInt64 = 0x80_0000

  /// Parses raw event flags. The same bits arrive as `CGEventFlags.rawValue` in the tap and as
  /// `NSEvent.ModifierFlags.rawValue` in the Settings recorder, so both build `HeldKeys` here.
  /// A family whose generic flag is set but no device bit (a synthetic event or a remapper)
  /// takes the side `changedKey` names, else the left side. Fn counts only on a flags change:
  /// arrow and F-key key-downs carry the Fn bit without Fn held.
  public init(rawFlags: UInt64, changedKey: KeyCode?, isFlagsChange: Bool) {
    var held: HeldKeys = []
    for family in ModifierKey.allCases where rawFlags & family.flagMask != 0 {
      let sides = [family.left, family.right].filter { rawFlags & $0.deviceMask != 0 }
      if sides.isEmpty {
        if let changed = changedKey.flatMap(HoldKey.init(keyCode:)), changed.family == family {
          held.insert(HeldKeys(changed))
        } else {
          held.insert(HeldKeys(family.left))
        }
      } else {
        for side in sides { held.insert(HeldKeys(side)) }
      }
    }
    if isFlagsChange, rawFlags & Self.secondaryFnMask != 0 { held.insert(HeldKeys(.fn)) }
    self = held
  }

  /// Sideless projection. Fn projects to nothing.
  public var modifiers: Modifiers {
    var modifiers: Modifiers = []
    for key in keys {
      if let family = key.family { modifiers.insert(family.modifiers) }
    }
    return modifiers
  }

  /// The one key held, when exactly one is.
  var only: HoldKey? {
    guard rawValue.nonzeroBitCount == 1 else { return nil }
    return HoldKey.allCases.first { $0.bit == rawValue }
  }

  public func contains(_ key: HoldKey) -> Bool { contains(HeldKeys(key)) }

  /// Ordered for the setup key caps: ⌃ ⌥ ⇧ ⌘ Fn, left before right.
  public var keys: [HoldKey] {
    let order: [HoldKey] = [
      .leftControl, .rightControl, .leftOption, .rightOption, .leftShift, .rightShift, .leftCommand,
      .rightCommand, .fn,
    ]
    return order.filter { contains(HeldKeys($0)) }
  }
}
