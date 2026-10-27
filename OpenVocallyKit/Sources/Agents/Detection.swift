#if FEATURE_AGENTS
  import Darwin
  import Foundation

  struct Candidate: Sendable, Equatable {
    var path: URL
    var origin: Installation.Origin
  }

  enum Detection {
    /// Chosen path first, then `<dir>/<executable>` per PATH directory, then known locations.
    /// De-duplicated on the literal path, so two symlinks to one binary are both tried.
    static func candidates(
      spec: AgentSpec, chosen: URL?, searchDirectories: [URL], known: [URL]
    ) -> [Candidate] {
      var seen = Set<String>()
      let all =
        (chosen.map { [Candidate(path: $0, origin: .chosen)] } ?? [])
        + searchDirectories.map {
          Candidate(path: $0.appending(path: spec.executableName), origin: .loginShellPath)
        }
        + known.map { Candidate(path: $0, origin: .knownLocation) }
      return all.filter { seen.insert($0.path.standardizedFileURL.path(percentEncoded: false)).inserted }
    }

    /// Walks the candidates in order and stops at the first copy that runs. Every copy passed over,
    /// except a PATH entry that simply is not there, becomes a `SkippedCopy`.
    @concurrent
    static func firstWorkingCopy(
      _ candidates: [Candidate], spec: AgentSpec, environment: [String: String], home: URL, timeout: Duration
    ) async -> (Installation?, [SkippedCopy]) {
      var skipped: [SkippedCopy] = []
      for candidate in candidates {
        if Task.isCancelled { break }
        let path = candidate.path.path(percentEncoded: false)
        func skip(_ reason: SkippedCopy.Reason) {
          skipped.append(SkippedCopy(path: candidate.path, origin: candidate.origin, reason: reason))
        }
        var link = stat()
        guard lstat(path, &link) == 0 else {
          if candidate.origin == .chosen { skip(.missing) }
          continue
        }
        var target = stat()
        guard stat(path, &target) == 0 else {
          skip(.danglingSymlink)
          continue
        }
        guard target.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else {
          skip(.notExecutable)
          continue
        }
        let result = await Subprocess.run(
          candidate.path, ["--version"], environment: environment, timeout: timeout)
        switch result.ending {
        case .timedOut: skip(.timedOut)
        case .couldNotStart: skip(.couldNotStart)
        case .signaled(let signal): skip(.crashed(signal: signal))
        case .exited(let code) where code != 0: skip(.failedToRun(exitCode: code))
        case .exited:
          guard let version = CLIVersion.firstToken(in: result.stdout) else {
            skip(.unreadableVersion)
            continue
          }
          let resolved = candidate.path.resolvingSymlinksInPath()
          let ownership = InstallOwnership.classify(
            found: candidate.path, resolved: resolved, spec: spec, home: home)
          let installation = Installation(
            path: candidate.path, resolved: resolved, origin: candidate.origin, ownership: ownership,
            version: version)
          return (installation, skipped)
        }
      }
      return (nil, skipped)
    }

    /// The PATH every probe gets: the login PATH, then the known directories, so
    /// `#!/usr/bin/env node` resolves even when the shell could not be read.
    static func probePATH(_ existing: String?, known: [URL]) -> String {
      var seen = Set<String>()
      let parts =
        (existing ?? "").split(separator: ":").map(String.init)
        + known.map { $0.deletingLastPathComponent().path(percentEncoded: false) }
      return parts.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
  }

  /// What a search found, with the environment and directories it searched, so an update runs in the
  /// same environment and looks for npm where the CLI was looked for.
  struct Located: Sendable {
    var installation: Installation?
    var skipped: [SkippedCopy]
    var probeEnvironment: [String: String]
    var searchDirectories: [URL]
  }

  /// Detect, gate on the version, then ask for sign-in. Total: every failure is a `ProviderHealth`.
  enum HealthCheck {
    @concurrent
    static func run(
      _ kind: AgentKind, _ configuration: ProviderConfiguration, _ environment: AgentEnvironment,
      loginEnvironment: LoginEnvironment
    ) async -> ProviderHealth {
      let spec = kind.spec
      let located = await locate(kind, configuration, environment, loginEnvironment: loginEnvironment)
      let skipped = located.skipped
      guard let installation = located.installation else {
        return skipped.contains(where: \.existsOnDisk)
          ? .needsAttention(skipped: skipped) : .notFound(skipped: skipped)
      }
      guard installation.version >= spec.minimumVersion else {
        return .unsupported(installation, skipped: skipped)
      }
      let result = await Subprocess.run(
        installation.path, spec.signInArguments, environment: located.probeEnvironment,
        timeout: environment.timeouts.signIn)
      return .installed(installation, spec.parseSignIn(result), skipped: skipped)
    }

    /// Candidates, then the first copy that runs. An update calls this too, so both search alike.
    @concurrent
    static func locate(
      _ kind: AgentKind, _ configuration: ProviderConfiguration, _ environment: AgentEnvironment,
      loginEnvironment: LoginEnvironment
    ) async -> Located {
      let spec = kind.spec
      let probeEnvironment: [String: String]
      let searchDirectories: [URL]
      let known: [URL]
      switch environment.search {
      case .live:
        known = spec.knownLocations(environment.home)
        var login = await loginEnvironment.current()
        searchDirectories = (login["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)) }
        login["PATH"] = Detection.probePATH(login["PATH"], known: known)
        probeEnvironment = login
      case .only(let directories, let given):
        known = []
        searchDirectories = directories
        probeEnvironment = given
      }
      let candidates = Detection.candidates(
        spec: spec, chosen: configuration.chosenPath, searchDirectories: searchDirectories, known: known)
      let (found, skipped) = await Detection.firstWorkingCopy(
        candidates, spec: spec, environment: probeEnvironment, home: environment.home,
        timeout: environment.timeouts.version)
      return Located(
        installation: found, skipped: skipped, probeEnvironment: probeEnvironment,
        searchDirectories: searchDirectories)
    }
  }
#endif
