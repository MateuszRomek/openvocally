#if FEATURE_AGENTS
  /// The visible life of one update. A finished or failed run stays on screen until the next run or
  /// a configuration change.
  public enum UpdateRun: Sendable, Equatable {
    case idle
    /// Waiting for another update on the same npm prefix, Homebrew or binary.
    case queued
    case running
    case failed(UpdateFailure)
    case finished(UpdateOutcome)

    public var isActive: Bool { self == .queued || self == .running }

    /// One short line under the Update row; nil while idle.
    public var message: String? {
      switch self {
      case .idle: nil
      case .queued: "Waiting for another update…"
      case .running: "Updating…"
      case .failed(let failure): failure.message
      case .finished(let outcome): outcome.message
      }
    }

    /// Whether `message` reports a problem.
    public var isProblem: Bool {
      switch self {
      case .failed, .finished(.belowMinimum), .finished(.stillOutdated), .finished(.couldNotVerify): true
      default: false
      }
    }
  }

  public enum UpdateOutcome: Sendable, Equatable {
    /// Also when the install was already at or past the latest version and nothing ran.
    case updated(to: CLIVersion)
    /// It moved, but not far enough: sessions still refuse a version below the minimum.
    case belowMinimum(CLIVersion, minimum: CLIVersion)
    /// It exited 0 and the version did not move.
    case stillOutdated(CLIVersion)
    /// It exited 0 and the re-check found no working copy.
    case couldNotVerify

    public var message: String {
      switch self {
      case .updated(let version): "Updated to \(version). New sessions use it."
      case .belowMinimum(let version, let minimum):
        "Updated to \(version), but OpenVocally needs \(minimum) or newer."
      case .stillOutdated(let version): "Still on \(version) after the update."
      case .couldNotVerify: "Couldn’t confirm the new version."
      }
    }
  }

  /// Every reason fits on one line; the copyable command stays beside it.
  public enum UpdateFailure: Sendable, Equatable {
    case timedOut
    case exited(tool: String, code: Int32, lastLine: String?)
    case crashed(tool: String, signal: Int32)
    case couldNotStart(tool: String)
    case toolMissing(tool: String)
    case installationChanged
    case latestBelowMinimum(CLIVersion)

    public var message: String {
      switch self {
      case .timedOut: "Update timed out."
      case .exited(let tool, let code, let line?): "\(tool) exited with code \(code): \(line)"
      case .exited(let tool, let code, nil): "\(tool) exited with code \(code)."
      case .crashed(let tool, let signal): "\(tool) stopped by signal \(signal)."
      case .couldNotStart(let tool): "Couldn’t start \(tool)."
      case .toolMissing(let tool): "Couldn’t find \(tool)."
      case .installationChanged: "The install changed. Check again."
      case .latestBelowMinimum(let version): "The latest version, \(version), is too old for OpenVocally."
      }
    }
  }

  /// What Settings shows for an install that updates by command. Derived on read, never stored.
  public struct UpdateOffer: Sendable, Equatable {
    /// The latest version known for this install, whatever the advisory says. Nil while it has not
    /// been fetched yet.
    public let latest: CLIVersion?
    /// Whether there is anything to update: a newer version, or one below the minimum.
    public let isOutdated: Bool
    /// Why the button is off before anything runs.
    let refusal: UpdateFailure?
    public let run: UpdateRun

    /// Nil when there is nothing to update or no way to run the update. Kept while a run's outcome
    /// is on screen, so the row does not vanish under its own result.
    init?(installation: Installation, kind: AgentKind, latest: CLIVersion?, run: UpdateRun) {
      guard UpdateRecipe(installation, spec: kind.spec) != nil else { return nil }
      let minimum = kind.spec.minimumVersion
      let isOutdated = installation.version < minimum || latest.map { $0 > installation.version } ?? false
      guard isOutdated || run != .idle else { return nil }
      self.latest = latest
      self.isOutdated = isOutdated
      // Uses the latest known version whatever the advisory says. A latest at or below an
      // unsupported install is also below the minimum, so this one rule refuses both.
      refusal = latest.flatMap { $0 < minimum ? .latestBelowMinimum($0) : nil }
      self.run = run
    }

    public var canStart: Bool { isOutdated && refusal == nil && !run.isActive }

    /// What the line under the row says, if anything.
    public var message: String? { refusal?.message ?? run.message }

    /// Whether that line reports a problem.
    public var isProblem: Bool { refusal != nil || run.isProblem }
  }
#endif
