#if FEATURE_AGENTS
  import Foundation

  /// How one install updates itself: the tool, run from the install's own prefix (or the CLI
  /// itself), and its arguments. Pure: built from an `Installation` with no file system access.
  struct UpdateRecipe: Sendable, Equatable {
    enum Tool: Sendable, Equatable {
      /// This exact file: Homebrew's `<prefix>/bin/brew`, or the CLI itself.
      case file(URL)
      /// `<prefix>/bin/npm` when it exists, else the first `npm` in the search directories.
      case npm(prefix: URL)
    }

    let tool: Tool
    /// For messages and logs: "npm", "brew" or the CLI's name.
    let toolName: String
    let arguments: [String]
    let lock: UpdateLockKey

    /// Nil for bundled and unknown installs: no Update button.
    init?(_ installation: Installation, spec: AgentSpec) {
      switch installation.ownership {
      case .npm(let package, let prefix):
        tool = .npm(prefix: prefix)
        toolName = "npm"
        arguments = ["install", "-g", "--prefix", prefix.path(percentEncoded: false), "\(package)@latest"]
        lock = .npm(prefix.standardizedFileURL)
      case .homebrew(let package, let prefix):
        tool = .file(prefix.appending(path: "bin/brew"))
        toolName = "brew"
        arguments =
          switch package {
          case .formula(let name): ["upgrade", name]
          case .cask(let name): ["upgrade", "--cask", name]
          }
        lock = .homebrew(prefix.standardizedFileURL)
      case .nativeInstaller:
        tool = .file(installation.path)
        toolName = spec.executableName
        arguments = ["update"]
        lock = .file(installation.path.standardizedFileURL)
      case .bundled, .unknown:
        return nil
      }
    }
  }

  /// Updates sharing a key never run at once: same npm prefix, same Homebrew, same binary.
  enum UpdateLockKey: Sendable, Hashable {
    case npm(URL)
    case homebrew(URL)
    case file(URL)
  }

  /// The process side of one update, off the main actor. Takes values and returns a value.
  enum CLIUpdate {
    static let outputTail = 10 * 1024
    static let lineLimit = 160

    /// Finds the tool without a shell, runs it, and turns the ending into nil (exit 0) or a failure.
    @concurrent
    static func run(
      _ recipe: UpdateRecipe, searchDirectories: [URL], environment: [String: String], timeout: Duration
    ) async -> UpdateFailure? {
      let candidates: [URL] =
        switch recipe.tool {
        case .file(let url): [url]
        case .npm(let prefix):
          [prefix.appending(path: "bin/npm")] + searchDirectories.map { $0.appending(path: "npm") }
        }
      guard let executable = candidates.first(where: isExecutableFile) else {
        return .toolMissing(tool: recipe.toolName)
      }
      var environment = environment
      // npm is `#!/usr/bin/env node`: the node beside the npm we picked must win.
      let directory = executable.deletingLastPathComponent().path(percentEncoded: false)
      environment["PATH"] = [directory, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
      agentsLogger.info(
        "Updating with \(recipe.toolName, privacy: .public) at \(executable.path(percentEncoded: false), privacy: .private)"
      )
      // npm runs a package's install scripts; without the disclaim they would run with the app's
      // Accessibility and Microphone grants, so the update does not start without it.
      let result = await Subprocess.run(
        executable, recipe.arguments, environment: environment, timeout: timeout, output: .tail(outputTail),
        requireDisclaim: true)
      switch result.ending {
      case .exited(0):
        agentsLogger.info("\(recipe.toolName, privacy: .public) exited with code 0")
        return nil
      case .exited(let code):
        agentsLogger.notice("\(recipe.toolName, privacy: .public) exited with code \(code, privacy: .public)")
        return .exited(
          tool: recipe.toolName, code: code, lastLine: lastLine(result.stderr) ?? lastLine(result.stdout))
      case .signaled(let signal):
        agentsLogger.notice(
          "\(recipe.toolName, privacy: .public) stopped by signal \(signal, privacy: .public)")
        return .crashed(tool: recipe.toolName, signal: signal)
      case .timedOut:
        agentsLogger.notice("\(recipe.toolName, privacy: .public) timed out")
        return .timedOut
      case .couldNotStart:
        return .couldNotStart(tool: recipe.toolName)
      }
    }

    /// The last non-empty line, terminal escapes and control characters removed, clipped.
    static func lastLine(_ output: String) -> String? {
      let plain = output.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
      let line = plain.split(whereSeparator: \.isNewline).lazy
        .map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last(where: { !$0.isEmpty })
      guard let line else { return nil }
      return line.count > lineLimit ? String(line.prefix(lineLimit - 1)) + "…" : line
    }

    /// Same file, same owner. Never compares the resolved path: for Homebrew and native installs it
    /// names the version, and an update made in Terminal must still count as the same install.
    static func isSameInstall(_ shown: Installation, _ fresh: Installation) -> Bool {
      guard shown.path.standardizedFileURL == fresh.path.standardizedFileURL else { return false }
      return switch (shown.ownership, fresh.ownership) {
      case (.npm(let a, let p), .npm(let b, let q)): a == b && p.standardizedFileURL == q.standardizedFileURL
      case (.homebrew(let a, let p), .homebrew(let b, let q)):
        a == b && p.standardizedFileURL == q.standardizedFileURL
      case (.nativeInstaller, .nativeInstaller), (.bundled, .bundled), (.unknown, .unknown): true
      default: false
      }
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
      var isDirectory: ObjCBool = false
      let path = url.path(percentEncoded: false)
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
    }
  }
#endif
