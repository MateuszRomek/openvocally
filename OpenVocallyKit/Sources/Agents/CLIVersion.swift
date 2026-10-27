#if FEATURE_AGENTS
  /// `major.minor.patch` with an optional prerelease, ordered by SemVer. "0.162" reads as 0.162.0.
  public struct CLIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init(_ major: Int, _ minor: Int, _ patch: Int = 0, prerelease: String? = nil) {
      self.major = major
      self.minor = minor
      self.patch = patch
      self.prerelease = prerelease
    }

    /// The whole string must be a version, as in a registry answer or a cached value.
    public init?(_ exact: String) {
      guard let match = exact.wholeMatch(of: Self.pattern) else { return nil }
      self.init(match)
    }

    /// The first version-shaped token in a CLI's output, such as "codex-cli 0.164.0-alpha.11.1".
    static func firstToken(in output: String) -> CLIVersion? {
      output.firstMatch(of: pattern).flatMap(CLIVersion.init)
    }

    private init?(_ match: Regex<(Substring, Substring, Substring, Substring?, Substring?)>.Match) {
      guard let major = Int(match.1), let minor = Int(match.2) else { return nil }
      let patch = match.3.map { Int($0) } ?? 0
      guard let patch else { return nil }
      self.init(major, minor, patch, prerelease: match.4.map(String.init))
    }

    /// Computed, because a `Regex` is not `Sendable` and so cannot be a shared static constant.
    private static var pattern: Regex<(Substring, Substring, Substring, Substring?, Substring?)> {
      /(\d{1,9})\.(\d{1,9})(?:\.(\d{1,9}))?(?:-([0-9A-Za-z.-]+))?/
    }

    public static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
      if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
        return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
      }
      switch (lhs.prerelease, rhs.prerelease) {
      case (nil, _): return false
      case (_, nil): return true
      case (let left?, let right?): return Self.precedes(left, right)
      }
    }

    /// SemVer 11.4: dot-separated identifiers, numeric ones compared as numbers and ranked below
    /// alphanumeric ones, and a shorter list first when every shared identifier is equal.
    private static func precedes(_ left: String, _ right: String) -> Bool {
      let lhs = left.split(separator: ".", omittingEmptySubsequences: false)
      let rhs = right.split(separator: ".", omittingEmptySubsequences: false)
      for (a, b) in zip(lhs, rhs) where a != b {
        switch (Int(a), Int(b)) {
        case (let x?, let y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a < b
        }
      }
      return lhs.count < rhs.count
    }

    public var description: String {
      "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }
  }
#endif
