#if FEATURE_AGENTS
  import Foundation

  /// One provider's local health as one value. Every status and detail line derives from it, so
  /// Settings, the start card and a thread's error line cannot disagree. Sign-in exists only where it
  /// was asked: an unsupported version is never probed for sign-in.
  public enum ProviderHealth: Sendable, Equatable {
    case disabled
    /// The first check, or the check after a configuration change. A re-check keeps the last result.
    case checking
    /// Nothing on disk anywhere we looked.
    case notFound(skipped: [SkippedCopy])
    /// At least one copy is on disk and none of them runs.
    case needsAttention(skipped: [SkippedCopy])
    case unsupported(Installation, skipped: [SkippedCopy])
    case installed(Installation, SignIn, skipped: [SkippedCopy])

    public var status: HealthStatus {
      switch self {
      case .disabled: .disabled
      case .checking: .checking
      case .notFound: .notFound
      case .needsAttention: .needsAttention
      case .unsupported: .unsupportedVersion
      case .installed(_, .signedIn, _): .available
      case .installed(_, .signedOut, _): .notAuthenticated
      case .installed(_, .unconfirmed, _): .couldntConfirmSignIn
      }
    }

    /// Whether a session may not start. A sign-in we could not read does not block.
    var blocksUse: Bool {
      switch self {
      case .installed(_, .signedOut, _): true
      case .installed: false
      default: true
      }
    }

    public var installation: Installation? {
      switch self {
      case .unsupported(let installation, _), .installed(let installation, _, _): installation
      default: nil
      }
    }

    public var signIn: SignIn? {
      if case .installed(_, let signIn, _) = self { signIn } else { nil }
    }

    public var skipped: [SkippedCopy] {
      switch self {
      case .disabled, .checking: []
      case .notFound(let skipped), .needsAttention(let skipped), .unsupported(_, let skipped),
        .installed(_, _, let skipped):
        skipped
      }
    }

    /// The line under the status title, worded once for every surface.
    public func detail(for kind: AgentKind) -> String {
      let spec = kind.spec
      switch self {
      case .disabled: return "Turn on to use \(spec.displayName)."
      case .checking: return "Looking for \(spec.executableName)…"
      case .notFound: return "\(spec.executableName) isn’t installed on this Mac."
      case .needsAttention:
        return "Found \(spec.executableName), but it doesn’t start. Choose a copy that works."
      case .unsupported(let installation, _):
        let older = "Version \(installation.version) is older than \(spec.minimumVersion)."
        return UpdateRecipe(installation, spec: spec) == nil
          ? "\(older) Update it the way you installed it." : "\(older) Update to use it."
      case .installed(let installation, let signIn, _):
        switch signIn {
        case .signedIn(let method?): return "Version \(installation.version), signed in with \(method)."
        case .signedIn(nil): return "Version \(installation.version), signed in."
        case .signedOut: return "Run \(spec.loginCommand) in Terminal to sign in."
        case .unconfirmed: return "Couldn’t read the sign-in status. Sessions can still start."
        }
      }
    }
  }

  /// T3 Code's wording, plus Disabled and Checking.
  public enum HealthStatus: String, CaseIterable, Sendable {
    case disabled
    case checking
    case notFound
    case needsAttention
    case unsupportedVersion
    case notAuthenticated
    case couldntConfirmSignIn
    case available

    public var title: String {
      switch self {
      case .disabled: "Disabled"
      case .checking: "Checking…"
      case .notFound: "Not found"
      case .needsAttention: "Needs attention"
      case .unsupportedVersion: "Unsupported version"
      case .notAuthenticated: "Not authenticated"
      case .couldntConfirmSignIn: "Couldn’t confirm sign-in"
      case .available: "Available"
      }
    }
  }

  /// A CLI that ran. `path` is what we launch, symlinks kept; `resolved` has them followed.
  public struct Installation: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
      case chosen
      case loginShellPath
      case knownLocation
    }

    public let path: URL
    let resolved: URL
    let origin: Origin
    public let ownership: InstallOwnership
    public let version: CLIVersion
  }

  /// A copy the walk passed over. Becomes a quiet note under the path.
  public struct SkippedCopy: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
      /// Only recorded for the chosen path; a PATH directory without the binary is not news.
      case missing
      case danglingSymlink
      case notExecutable
      case couldNotStart
      case failedToRun(exitCode: Int32)
      case crashed(signal: Int32)
      case timedOut
      /// It exited 0 but printed no version.
      case unreadableVersion
    }

    let path: URL
    let origin: Installation.Origin
    let reason: Reason

    /// The one quiet line Settings shows for every copy the walk passed over; each `note` goes in
    /// its help tag and VoiceOver value.
    public static func summary(_ skipped: [SkippedCopy]) -> String? {
      switch skipped.count {
      case 0: nil
      case 1: "Skipped a copy that doesn’t run."
      default: "Skipped \(skipped.count) copies that don’t run."
      }
    }

    /// One line, with no CLI output in it.
    public var note: String {
      let path = path.path(percentEncoded: false)
      return switch reason {
      case .missing: "Skipped \(path): it no longer exists."
      case .danglingSymlink: "Skipped \(path): the link points nowhere."
      case .notExecutable: "Skipped \(path): it isn’t executable."
      case .couldNotStart: "Skipped \(path): it couldn’t start."
      case .failedToRun(let code): "Skipped \(path): it exited with code \(code)."
      case .crashed(let signal): "Skipped \(path): it was stopped by signal \(signal)."
      case .timedOut: "Skipped \(path): it didn’t answer in time."
      case .unreadableVersion: "Skipped \(path): it printed no version."
      }
    }

    /// Needs attention requires at least one of these: a file that is there and does not run.
    var existsOnDisk: Bool {
      switch reason {
      case .missing, .danglingSymlink: false
      default: true
      }
    }
  }
#endif
