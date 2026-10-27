#if FEATURE_AGENTS
  import Foundation

  public enum SignIn: Sendable, Equatable {
    /// `method` is a label such as "ChatGPT" or "Claude account", never an email or organization.
    case signedIn(method: String?)
    case signedOut
    /// The status command did not answer in a way we read. Does not block.
    case unconfirmed(Cause)

    public enum Cause: Sendable, Equatable {
      case timedOut
      case unreadable
      case couldNotStart
    }
  }

  /// The text decides, not the exit code alone: both CLIs exit 1 when signed out, and a crash exits
  /// non-zero too. Email, organization and account ids are never read.
  enum SignInParser {
    /// `claude auth status --json` prints `{"loggedIn": Bool, "authMethod": String}`.
    static func claude(_ result: ProbeResult) -> SignIn {
      if let cause = failure(result) { return .unconfirmed(cause) }
      guard let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(result.stdout.utf8))
      else { return .unconfirmed(.unreadable) }
      guard status.loggedIn else { return .signedOut }
      let method: String? =
        switch status.authMethod {
        case "claude.ai": "Claude account"
        case "console", "apiKey", "api_key": "API key"
        default: nil
        }
      return .signedIn(method: method)
    }

    /// `codex login status` writes "Logged in using X" or "Not logged in", usually to stderr.
    static func codex(_ result: ProbeResult) -> SignIn {
      if let cause = failure(result) { return .unconfirmed(cause) }
      let lines = (result.stderr + "\n" + result.stdout).split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      let prefix = "Logged in using "
      if case .exited(0) = result.ending, let line = lines.first(where: { $0.hasPrefix(prefix) }) {
        return .signedIn(method: codexMethod(line.dropFirst(prefix.count)))
      }
      if case .exited(1) = result.ending, lines.contains(where: { $0.hasPrefix("Not logged in") }) {
        return .signedOut
      }
      return .unconfirmed(.unreadable)
    }

    /// A fixed label set, because the rest of the line can carry a masked key or account detail.
    static func codexMethod(_ remainder: Substring) -> String? {
      let text = remainder.trimmingCharacters(in: .whitespaces)
      if text == "ChatGPT" { return "ChatGPT" }
      if text.localizedCaseInsensitiveContains("API key") { return "API key" }
      if text.localizedCaseInsensitiveContains("access token") { return "access token" }
      return nil
    }

    private static func failure(_ result: ProbeResult) -> SignIn.Cause? {
      switch result.ending {
      case .timedOut: .timedOut
      case .couldNotStart: .couldNotStart
      case .exited, .signaled: nil
      }
    }

    private struct ClaudeAuthStatus: Decodable {
      let loggedIn: Bool
      let authMethod: String?
    }
  }
#endif
