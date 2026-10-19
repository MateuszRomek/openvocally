import Foundation

/// What macOS does with Fn / Globe alone (com.apple.HIToolbox AppleFnUsageType).
public enum FnUsage: Sendable, Equatable {
  case doNothing
  case changeInputSource
  case showEmoji
  case startDictation
  /// Key missing or an unknown value. macOS then uses its own default, which is not Do Nothing.
  case systemDefault

  public init(storedValue: Int?) {
    switch storedValue {
    case 0: self = .doNothing
    case 1: self = .changeInputSource
    case 2: self = .showEmoji
    case 3: self = .startDictation
    default: self = .systemDefault
    }
  }
}

/// The current keyboard layout's ⌥ layer. Plain data, so the risk rule is testable without Carbon.
struct OptionLayer: Sendable, Equatable {
  /// BCP 47 language of the input source, such as "pl".
  let language: String?
  /// What each letter key types without and with ⌥, dead keys excluded.
  let base: Set<Character>
  let option: Set<Character>
}

public enum HoldKeyWarning: Sendable, Equatable {
  case optionTypesLetters(HoldKey, language: String, examples: [Character])
  case fnHasSystemAction(FnUsage)
  case shiftTypesCapitals(HoldKey)
  /// The left ⌘ and ⌃ start most shortcuts; each one would open the mic until it is dropped.
  case usedForShortcuts(HoldKey)

  public var message: String {
    switch self {
    case .optionTypesLetters(let key, let language, _):
      "\(key.label) types \(language) letters. You'd start recording while typing."
    case .fnHasSystemAction(let usage):
      "macOS uses Fn to \(usage.actionPhrase). Set Globe key to Do Nothing in Keyboard settings."
    case .shiftTypesCapitals:
      "You hold ⇧ for capitals, so recording would start while typing."
    case .usedForShortcuts(let key):
      "Most shortcuts use \(key.label), so the mic would open briefly with each one. "
        + "\(key.family?.right.label ?? "The right key") is rarely used."
    }
  }
}

extension FnUsage {
  fileprivate var actionPhrase: String {
    switch self {
    case .doNothing: "do nothing"
    case .changeInputSource: "change the input source"
    case .showEmoji: "show emoji"
    case .startDictation: "start Dictation"
    case .systemDefault: "do something"
    }
  }
}

enum HoldKeyRisk {
  /// Pure. `letters` is the language's exemplar letters, passed in so tests do not depend on
  /// the host's locale data. ⌥ warns only when it types letters of the layout's own language
  /// (Polish ą, ę), not symbols (US å, ß).
  static func warning(
    for key: HoldKey, layer: OptionLayer, letters: Set<Character>, fnUsage: FnUsage
  ) -> HoldKeyWarning? {
    switch key {
    case .fn:
      return fnUsage == .doNothing ? nil : .fnHasSystemAction(fnUsage)
    case .leftShift, .rightShift:
      return .shiftTypesCapitals(key)
    case .leftOption, .rightOption:
      let lowerLetters = Set(letters.map { $0.lowercased() })
      let gained = layer.option.subtracting(layer.base).filter { lowerLetters.contains($0.lowercased()) }
      guard !gained.isEmpty else { return nil }
      let language =
        layer.language.flatMap { Locale(identifier: "en_US").localizedString(forLanguageCode: $0) }
        ?? "accented"
      return .optionTypesLetters(key, language: language, examples: Array(gained.sorted().prefix(3)))
    case .leftCommand, .leftControl:
      return .usedForShortcuts(key)
    case .rightCommand, .rightControl:
      return nil
    }
  }
}
