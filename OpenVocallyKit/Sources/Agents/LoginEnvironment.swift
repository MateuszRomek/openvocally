#if FEATURE_AGENTS
  import Darwin
  import Foundation
  import Synchronization

  /// The user's login-shell environment, read once and kept until Settings is shown again. Probes run
  /// with it, because an npm install is `#!/usr/bin/env node` and needs the user's PATH, and Claude
  /// reads proxy and API variables from it. Held in memory only: never logged, never persisted.
  ///
  /// A class around a lock rather than an actor, so `invalidate()` is synchronous and lands before the
  /// checks that the same refresh starts.
  final class LoginEnvironment: Sendable {
    private let shell: URL
    private let timeout: Duration
    private let fallbackDirectories: [URL]
    private let read = Mutex<Task<[String: String]?, Never>?>(nil)

    /// `shell` is for tests; by default it is the account's shell when /etc/shells lists it.
    init(shell: URL? = nil, timeout: Duration, fallbackDirectories: [URL]) {
      self.shell = shell ?? Self.accountShell()
      self.timeout = timeout
      self.fallbackDirectories = fallbackDirectories
    }

    /// Joins a read in flight. On failure or timeout, the app's environment with a minimal PATH plus
    /// the known install directories, so detection still finds common installs. Only a successful
    /// read is kept, so the next check tries the shell again.
    func current() async -> [String: String] {
      let task = read.withLock { pending in
        if let pending { return pending }
        let task = Task { [shell, timeout] in await Self.resolve(shell: shell, timeout: timeout) }
        pending = task
        return task
      }
      if let environment = await task.value { return environment }
      read.withLock { if $0 == task { $0 = nil } }
      return Self.fallback(directories: fallbackDirectories)
    }

    func invalidate() {
      read.withLock { $0 = nil }
    }

    /// A constant: nothing the user or the app chose is ever put into it. `-i` loads .zshrc, where
    /// version managers such as nvm set PATH; the sentinels discard whatever the rc files print.
    static let command =
      "printf '%s' '__OPENVOCALLY_ENV_START__'; /usr/bin/env -0; printf '%s' '__OPENVOCALLY_ENV_END__'"

    @concurrent
    private static func resolve(shell: URL, timeout: Duration) async -> [String: String]? {
      var environment = ProcessInfo.processInfo.environment
      environment[resolvingMarker] = "1"
      let result = await Subprocess.run(
        shell, ["-l", "-i", "-c", command], environment: environment, timeout: timeout)
      guard case .exited = result.ending, var parsed = parse(result.stdout), parsed["PATH"] != nil else {
        agentsLogger.notice("Login shell environment unavailable; using the fallback PATH")
        return nil
      }
      // Lets rc files tell this read from a terminal login; a CLI started later must not inherit it.
      parsed[resolvingMarker] = nil
      return parsed
    }

    static let resolvingMarker = "OPENVOCALLY_RESOLVING_ENVIRONMENT"

    static func parse(_ output: String) -> [String: String]? {
      guard let start = output.range(of: "__OPENVOCALLY_ENV_START__"),
        let end = output.range(of: "__OPENVOCALLY_ENV_END__", range: start.upperBound..<output.endIndex)
      else { return nil }
      var environment: [String: String] = [:]
      for entry in output[start.upperBound..<end.lowerBound].split(separator: "\0") {
        guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
        environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
      }
      return environment
    }

    static func fallback(directories: [URL]) -> [String: String] {
      var environment = ProcessInfo.processInfo.environment
      let extra = directories.map { $0.path(percentEncoded: false) }
      var seen = Set<String>()
      environment["PATH"] = (["/usr/bin", "/bin", "/usr/sbin", "/sbin"] + extra)
        .filter { seen.insert($0).inserted }.joined(separator: ":")
      return environment
    }

    private static func accountShell() -> URL {
      let fallback = URL(filePath: "/bin/zsh")
      guard let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell else { return fallback }
      let shell = String(cString: raw)
      guard let listed = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else { return fallback }
      let shells = listed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      return shells.contains(shell) && shell.hasPrefix("/") ? URL(filePath: shell) : fallback
    }
  }
#endif
