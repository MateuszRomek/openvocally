import Foundation

/// A JSON value with sorted-key encoding, so every frame the fakes write is byte-stable.
package enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  package init(data: Data) throws {
    self = Self(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }

  private init(any: Any) {
    switch any {
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
      self = .bool(number.boolValue)
    case let number as NSNumber: self = .number(number.doubleValue)
    case let string as String: self = .string(string)
    case let array as [Any]: self = .array(array.map(Self.init(any:)))
    case let object as [String: Any]: self = .object(object.mapValues(Self.init(any:)))
    default: self = .null
    }
  }

  package var data: Data { Data(text.utf8) }

  package var text: String {
    switch self {
    case .null: "null"
    case .bool(let value): value ? "true" : "false"
    case .number(let value):
      value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    case .string(let value): Self.quoted(value)
    case .array(let values): "[" + values.map(\.text).joined(separator: ",") + "]"
    case .object(let values):
      "{"
        + values.sorted { $0.key < $1.key }.map { Self.quoted($0.key) + ":" + $0.value.text }
        .joined(separator: ",") + "}"
    }
  }

  private static func quoted(_ string: String) -> String {
    var out = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  package subscript(key: String) -> JSONValue? {
    if case .object(let values) = self { values[key] } else { nil }
  }

  package var string: String? { if case .string(let value) = self { value } else { nil } }
  package var array: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
  package var object: [String: JSONValue]? { if case .object(let values) = self { values } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  package init(stringLiteral value: String) { self = .string(value) }
  package init(integerLiteral value: Int) { self = .number(Double(value)) }
  package init(booleanLiteral value: Bool) { self = .bool(value) }
  package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  package init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  package init(nilLiteral: ()) { self = .null }
}
