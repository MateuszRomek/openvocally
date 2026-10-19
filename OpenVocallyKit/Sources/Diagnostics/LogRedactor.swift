import Foundation

enum LogValue: Sendable, Equatable {
  case string(String?)
  case signed(Int64)
  case unsigned(UInt64)
  case double(Double)
  case other
}

/// One `OSLogMessageComponent`: the literal text before an argument, its placeholder and its value.
struct LogPiece: Sendable, Equatable {
  let literal: String
  let placeholder: String
  let value: LogValue
}

struct RedactedLine: Sendable, Equatable {
  let text: String
  let withheld: Bool

  fileprivate init(text: String, withheld: Bool) {
    self.text = text
    self.withheld = withheld
  }
}

enum LogRedactor {
  static let maxLineLength = 2_000
  private static let privateMarker = "<private>"
  private static let withheldMarker = "<message withheld>"

  static func redact(
    format: String, pieces: [LogPiece], date: Date, level: String, category: String
  ) -> RedactedLine {
    let message = render(format: format, pieces: pieces)
    let prefix =
      "\(date.formatted(lineDateStyle)) \(pad(level, 6)) \(pad(category, 12)) "
    var text = prefix + (message ?? withheldMarker)
    if text.count > maxLineLength {
      text = String(text.prefix(maxLineLength - 1)) + "…"
    }
    return RedactedLine(text: text, withheld: message == nil)
  }

  private static let lineDateStyle = Date.VerbatimFormatStyle(
    format:
      "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
    locale: Locale(identifier: "en_US_POSIX"),
    timeZone: .current,
    calendar: Calendar(identifier: .gregorian)
  )

  private static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
  }

  /// Returns nil when the pieces do not rebuild the format, so nothing unaccounted for is shown.
  private static func render(format: String, pieces: [LogPiece]) -> String? {
    guard let last = pieces.last, last.placeholder.isEmpty,
      pieces.dropLast().allSatisfy({ !$0.placeholder.isEmpty }),
      pieces.map({ $0.literal + $0.placeholder }).joined() == format
    else { return nil }
    return pieces.map { piece in
      piece.literal.replacingOccurrences(of: "%%", with: "%")
        + (piece.placeholder.isEmpty ? "" : argument(piece.placeholder, piece.value))
    }.joined()
  }

  private struct Placeholder {
    var tokens: [String] = []
    var precision: Precision = .none
    var conversion: Character = "@"

    enum Precision {
      case none
      case star
      case digits(Int)
    }

    init(_ text: String) {
      var rest = Substring(text.dropFirst())
      if rest.first == "{", let close = rest.firstIndex(of: "}") {
        tokens = rest[rest.index(after: rest.startIndex)..<close]
          .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        rest = rest[rest.index(after: close)...]
      }
      if let last = rest.last { conversion = last }
      if let dot = rest.firstIndex(of: ".") {
        let after = rest[rest.index(after: dot)...]
        if after.first == "*" {
          precision = .star
        } else if let digits = Int(after.prefix(while: \.isNumber)) {
          precision = .digits(digits)
        }
      }
    }

    var isPrivate: Bool {
      tokens.contains { $0 == "private" || $0 == "sensitive" || $0.hasPrefix("mask") }
    }
    var isPublic: Bool { tokens.contains("public") }
  }

  private static func argument(_ text: String, _ value: LogValue) -> String {
    let placeholder = Placeholder(text)
    if placeholder.isPrivate { return privateMarker }
    let conversion = placeholder.conversion
    switch conversion {
    case "d", "i", "u", "x", "X", "o":
      let bits: UInt64
      let signed: Int64?
      switch value {
      case .signed(let number):
        bits = UInt64(bitPattern: number)
        signed = number
      case .unsigned(let number):
        bits = number
        signed = nil
      default: return privateMarker
      }
      if placeholder.tokens.contains("bool") { return bits == 0 ? "false" : "true" }
      switch conversion {
      case "x": return String(bits, radix: 16)
      case "X": return String(bits, radix: 16, uppercase: true)
      case "o": return String(bits, radix: 8)
      default: return signed.map(String.init) ?? String(bits)
      }
    case "f", "F", "e", "E", "g", "G", "a", "A":
      guard case .double(let number) = value else { return privateMarker }
      switch placeholder.precision {
      // The store does not hand back a `.*` precision, so the value shows in full.
      case .star: return String(describing: number)
      case .digits(let digits): return String(format: "%.\(digits)\(conversion)", number)
      case .none: return String(format: "%\(conversion)", number)
      }
    default:
      guard placeholder.isPublic, case .string(let string?) = value else { return privateMarker }
      return string.replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    }
  }
}
