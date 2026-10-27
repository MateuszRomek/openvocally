#if FEATURE_AGENTS
  import Foundation

  /// Not named `Provider`: the fakes' `Provider` enum lives in AgentFakes, and the tests import both.
  public enum AgentKind: String, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    public var id: Self { self }

    public var spec: AgentSpec {
      switch self {
      case .claude: .claude
      case .codex: .codex
      }
    }
  }

  /// Every per-CLI fact, in one place. Other files read these fields and never switch on the kind.
  public struct AgentSpec: Sendable {
    public let displayName: String
    public let executableName: String
    /// Below it a session is blocked; above it only the update advisory speaks.
    let minimumVersion: CLIVersion
    /// Shown and copied, never run.
    public let loginCommand: String
    public let installCommand: String
    public let installGuide: URL
    public let launchArgumentsPlaceholder: String?
    public let launchArgumentsSubtitle: String
    let signInArguments: [String]
    let parseSignIn: @Sendable (ProbeResult) -> SignIn
    let npmPackage: String
    /// Homebrew names this CLI ships under. A Cellar or Caskroom name outside this list is not trusted,
    /// so no path segment ever reaches an update URL.
    let homebrew: [HomebrewPackage]
    /// Where the CLI's own installer puts it; such a copy updates with `<executable> update`.
    let nativeInstaller: NativeInstaller?
    /// Searched after the login-shell PATH. Version managers' shims come from that PATH instead.
    let knownLocations: @Sendable (_ home: URL) -> [URL]

    /// How a copy from the CLI's own installer is recognized, by its resolved path. The same rules
    /// as T3 Code's.
    enum NativeInstaller: Sendable {
      /// Under this directory, relative to home: Claude Code's `~/.local/share/claude`.
      case directory(String)
      /// Anywhere in the path: Codex's standalone install keeps its versions in `packages/standalone`.
      case pathContains(String)
    }

    static let claude = AgentSpec(
      displayName: "Claude Code",
      executableName: "claude",
      minimumVersion: CLIVersion(2, 1, 268),
      loginCommand: "claude auth login",
      installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
      installGuide: URL(literal: "https://docs.anthropic.com/en/docs/claude-code/setup"),
      launchArgumentsPlaceholder: "e.g. --chrome",
      launchArgumentsSubtitle: "Passed to claude when a session starts.",
      signInArguments: ["auth", "status", "--json"],
      parseSignIn: SignInParser.claude,
      npmPackage: "@anthropic-ai/claude-code",
      homebrew: [.cask("claude-code")],
      nativeInstaller: .directory(".local/share/claude"),
      knownLocations: { home in
        [
          home.appending(path: ".local/bin/claude"),
          home.appending(path: ".claude/local/claude"),
          URL(filePath: "/opt/homebrew/bin/claude"),
          URL(filePath: "/usr/local/bin/claude"),
          home.appending(path: ".npm-global/bin/claude"),
          home.appending(path: ".bun/bin/claude"),
          home.appending(path: ".volta/bin/claude"),
        ]
      }
    )

    static let codex = AgentSpec(
      displayName: "Codex",
      executableName: "codex",
      minimumVersion: CLIVersion(0, 162, 0),
      loginCommand: "codex login",
      installCommand: "npm install -g @openai/codex",
      installGuide: URL(literal: "https://github.com/openai/codex#installing-and-running-codex-cli"),
      launchArgumentsPlaceholder: nil,
      launchArgumentsSubtitle: "Passed to codex app-server when a session starts.",
      signInArguments: ["login", "status"],
      parseSignIn: SignInParser.codex,
      npmPackage: "@openai/codex",
      homebrew: [.formula("codex"), .cask("codex")],
      nativeInstaller: .pathContains("/packages/standalone/"),
      knownLocations: { home in
        let bundled = "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        return [
          URL(filePath: "/opt/homebrew/bin/codex"),
          URL(filePath: "/usr/local/bin/codex"),
          home.appending(path: ".local/bin/codex"),
          home.appending(path: ".npm-global/bin/codex"),
          home.appending(path: ".bun/bin/codex"),
          home.appending(path: ".volta/bin/codex"),
          URL(filePath: "/").appending(path: bundled),
          home.appending(path: bundled),
        ]
      }
    )
  }

  extension URL {
    /// A malformed literal is a programmer error, caught the first time the table is read.
    fileprivate init(literal: StaticString) {
      guard let url = URL(string: "\(literal)") else {
        preconditionFailure("Malformed URL literal \(literal)")
      }
      self = url
    }
  }
#endif
