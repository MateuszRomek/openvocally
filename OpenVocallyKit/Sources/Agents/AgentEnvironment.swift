#if FEATURE_AGENTS
  import Foundation
  import os

  let agentsLogger = Logger(subsystem: "com.openvocally.app", category: "agents")

  /// What a test or a Debug build swaps. Subprocesses stay real: a test points the search at fakes.
  public struct AgentEnvironment: Sendable {
    var home: URL
    public var search: Search
    public var latestVersions: @Sendable (LatestVersionSource) async throws -> CLIVersion
    var now: @Sendable () -> Date
    var timeouts = Timeouts()

    public enum Search: Sendable {
      /// Chosen path, then the login-shell PATH, then the known locations.
      case live
      /// Chosen path, then these directories, probed with this environment. No login shell and no
      /// known locations, so a CLI installed on the Mac never runs.
      case only(directories: [URL], environment: [String: String])
    }

    struct Timeouts: Sendable {
      var version: Duration = .seconds(5)
      var signIn: Duration = .seconds(5)
      var loginShell: Duration = .seconds(5)
      /// npm and brew can take minutes on a slow network.
      var update: Duration = .seconds(300)
    }

    public static func live() -> AgentEnvironment {
      AgentEnvironment(
        home: FileManager.default.homeDirectoryForCurrentUser,
        search: .live,
        latestVersions: { try await UpdateCheck.fetchLatest($0) },
        now: { Date() })
    }
  }
#endif
