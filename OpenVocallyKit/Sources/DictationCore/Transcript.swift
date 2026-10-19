/// Trimmed, non-empty text. Empty text cannot reach Paste because it cannot be built.
/// Neither description contains the text, so interpolating one into a log cannot leak it.
public struct Transcript: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public let text: String

  public init?(_ raw: String) {
    let trimmed = raw.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
    guard !trimmed.isEmpty else { return nil }
    text = String(trimmed)
  }

  public var description: String { "Transcript(\(text.count) characters)" }
  public var debugDescription: String { description }
}
