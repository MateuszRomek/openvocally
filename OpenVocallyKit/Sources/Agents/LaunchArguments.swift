#if FEATURE_AGENTS
  import Foundation

  /// The free-form field, kept as typed and split only when a launch needs the array.
  public struct LaunchArguments: Sendable, Equatable {
    public let text: String

    public init(_ text: String) { self.text = text }

    /// Whitespace separates. Single quotes keep everything literal. Double quotes keep everything
    /// literal except `\"` and `\\`. Outside quotes a backslash escapes the next character, and
    /// adjacent parts join into one argument. `$`, `~`, `*`, `;`, `|`, `&`, backticks and parentheses
    /// are ordinary characters: the result is an argv array that no shell ever reads.
    func split() throws(LaunchArgumentError) -> [String] {
      if text.contains("\0") { throw .containsNul }
      var arguments: [String] = []
      var current = ""
      var inArgument = false
      var characters = Array(text).enumerated().makeIterator()
      while let (offset, character) = characters.next() {
        switch character {
        case "'":
          inArgument = true
          while true {
            guard let (_, next) = characters.next() else { throw .unterminatedQuote(offset: offset) }
            if next == "'" { break }
            current.append(next)
          }
        case "\"":
          inArgument = true
          while true {
            guard let (_, next) = characters.next() else { throw .unterminatedQuote(offset: offset) }
            if next == "\"" { break }
            if next == "\\" {
              guard let (_, escaped) = characters.next() else { throw .unterminatedQuote(offset: offset) }
              if escaped != "\"" && escaped != "\\" { current.append("\\") }
              current.append(escaped)
            } else {
              current.append(next)
            }
          }
        case "\\":
          guard let (_, escaped) = characters.next() else { throw .trailingBackslash }
          inArgument = true
          current.append(escaped)
        case _ where character.isWhitespace:
          if inArgument { arguments.append(current) }
          current = ""
          inArgument = false
        default:
          inArgument = true
          current.append(character)
        }
      }
      if inArgument { arguments.append(current) }
      return arguments
    }

    /// For the field's inline error; nil when `split()` succeeds.
    public var problem: LaunchArgumentError? {
      do {
        _ = try split()
        return nil
      } catch {
        return error
      }
    }
  }

  public enum LaunchArgumentError: Error, Sendable, Equatable {
    /// `offset` is the character offset of the opening quote.
    case unterminatedQuote(offset: Int)
    case trailingBackslash
    /// A NUL cannot be passed to a process.
    case containsNul

    public var message: String {
      switch self {
      case .unterminatedQuote(let offset): "The quote at character \(offset + 1) is never closed."
      case .trailingBackslash: "Remove the backslash at the end, or escape it as \\\\."
      case .containsNul: "Remove the NUL character."
      }
    }
  }

  /// What a session launch needs: a path that ran and the argument tail. Never a shell string.
  struct LaunchCommand: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
  }

  enum LaunchCommandError: Error, Sendable, Equatable {
    case disabled
    /// Carries the status so the caller shows the same fix as Settings.
    case blocked(HealthStatus)
    case arguments(LaunchArgumentError)
    /// An update is rewriting the install.
    case updating
  }
#endif
