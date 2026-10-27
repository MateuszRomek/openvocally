#if FEATURE_AGENTS
  import Foundation

  /// Where the latest version is published. Built only from `InstallOwnership` and the spec table.
  public enum LatestVersionSource: Sendable, Hashable {
    case npm(package: String)
    case homebrewFormula(String)
    case homebrewCask(String)

    var cacheKey: String {
      switch self {
      case .npm(let package): "npm:\(package)"
      case .homebrewFormula(let name): "brew-formula:\(name)"
      case .homebrewCask(let name): "brew-cask:\(name)"
      }
    }

    /// The provider whose CLI this source publishes, so a Debug build can answer per provider.
    public var kind: AgentKind? {
      AgentKind.allCases.first { kind in
        let spec = kind.spec
        return switch self {
        case .npm(let package): package == spec.npmPackage
        case .homebrewFormula(let name): spec.homebrew.contains(.formula(name))
        case .homebrewCask(let name): spec.homebrew.contains(.cask(name))
        }
      }
    }

    var url: URL? {
      switch self {
      case .npm(let package): URL(string: "https://registry.npmjs.org/\(package)/latest")
      case .homebrewFormula(let name): URL(string: "https://formulae.brew.sh/api/formula/\(name).json")
      case .homebrewCask(let name): URL(string: "https://formulae.brew.sh/api/cask/\(name).json")
      }
    }
  }

  /// One JSON blob in UserDefaults keyed by source. A failure is recorded beside the last version
  /// fetched, never over it, so an offline Mac keeps its advisory and retries sooner without hammering.
  struct LatestVersionCache {
    struct Entry: Codable, Sendable, Equatable {
      struct Fetched: Codable, Sendable, Equatable {
        var version: String
        var at: Date
      }

      var lastFetched: Fetched?
      var lastFailureAt: Date?

      var version: CLIVersion? { lastFetched.flatMap { CLIVersion($0.version) } }

      /// The newer of the two decides: a success holds for four hours, a failure for fifteen minutes.
      func isFresh(now: Date) -> Bool {
        if let failure = lastFailureAt, failure >= (lastFetched?.at ?? .distantPast) {
          return LatestVersionCache.isWithin(failureLifetime, of: failure, now: now)
        }
        guard let lastFetched else { return false }
        return LatestVersionCache.isWithin(successLifetime, of: lastFetched.at, now: now)
      }
    }

    static let key = "agentsLatestVersions"
    static let successLifetime: TimeInterval = 4 * 3600
    static let failureLifetime: TimeInterval = 15 * 60

    let defaults: UserDefaults

    func entry(for source: LatestVersionSource) -> Entry { all()[source.cacheKey] ?? Entry() }

    /// Reads the stored entry at the time of the write, so a fetch that finished meanwhile is kept.
    func update(_ source: LatestVersionSource, _ change: (inout Entry) -> Void) {
      var entries = all()
      change(&entries[source.cacheKey, default: Entry()])
      if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }

    private static func isWithin(_ lifetime: TimeInterval, of date: Date, now: Date) -> Bool {
      let age = now.timeIntervalSince(date)
      return age >= 0 && age < lifetime
    }

    private func all() -> [String: Entry] {
      guard let data = defaults.data(forKey: Self.key) else { return [:] }
      return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
  }
#endif
