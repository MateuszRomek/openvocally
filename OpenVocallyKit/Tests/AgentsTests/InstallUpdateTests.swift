import Foundation
import Testing

@testable import Agents

/// The Update button end to end: real subprocesses against fake npm, brew and claude scripts.
@MainActor
struct InstallUpdateTests {
  static let claudePackage = "npm/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  static let codexPackage = "npm/lib/node_modules/@openai/codex/bin/codex.js"

  @Test func npmRunsWithItsPrefixAndTheNewVersionShows() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    let args = sandbox.url("npm.args")
    try sandbox.script("npm/bin/npm", "echo \"$@\" > '\(args.path)'\necho 9.9.9 > '\(cli.version.path)'")
    let service = sandbox.service()

    await service.refresh(.launch).value
    #expect(service.updateNotice != nil)
    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .finished(.updated(to: CLIVersion(9, 9, 9))))
    #expect(service[.claude].updateRun.message == "Updated to 9.9.9. New sessions use it.")
    #expect(service[.claude].health.installation?.version == CLIVersion(9, 9, 9))
    #expect(service[.claude].update == .current)
    #expect(service.updateNotice == nil)
    let prefix = sandbox.url("npm").path(percentEncoded: false)
    #expect(try sandbox.read(args) == "install -g --prefix \(prefix) @anthropic-ai/claude-code@latest\n")
  }

  @Test func homebrewRunsTheKegsOwnBrew() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned("brew/Cellar/codex/0.164.0/bin/codex", .codex, link: "brew/bin/codex")
    let args = sandbox.url("brew.args")
    try sandbox.script("brew/bin/brew", "echo \"$@\" > '\(args.path)'\necho 0.200.0 > '\(cli.version.path)'")
    let service = sandbox.service(latest: .success(CLIVersion(0, 200, 0)))

    await service.refresh(.launch).value
    #expect(service[.codex].updateOffer?.canStart == true)
    await service.installUpdate(for: .codex).value

    #expect(try sandbox.read(args) == "upgrade codex\n")
    #expect(service[.codex].updateRun == .finished(.updated(to: CLIVersion(0, 200, 0))))
  }

  @Test func aNativeClaudeRunsItsOwnUpdate() async throws {
    let sandbox = try Sandbox()
    let version = sandbox.url("claude.version")
    let cli = try sandbox.versioned(
      ".local/share/claude/versions/2.1.306", .claude, link: ".local/bin/claude",
      before: "if [ \"$1\" = update ]; then echo 9.9.9 > '\(version.path)'; exit 0; fi", version: version)
    let service = sandbox.service()

    await service.refresh(.launch).value
    #expect(service[.claude].health.installation?.ownership == .nativeInstaller)
    #expect(service[.claude].updateOffer?.canStart == true)
    await service.installUpdate(for: .claude).value

    #expect(try sandbox.read(cli.version) == "9.9.9\n")
    #expect(service[.claude].updateRun == .finished(.updated(to: CLIVersion(9, 9, 9))))
  }

  @Test func aStandaloneCodexRunsItsOwnUpdate() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(
      ".codex/packages/standalone/0.164.0/bin/codex", .codex, link: ".local/bin/codex",
      before: """
        if [ "$1" = update ]; then echo 0.200.0 > '\(sandbox.url("codex.version").path)'; exit 0; fi
        """)
    let service = sandbox.service(latest: .success(CLIVersion(0, 200, 0)))

    await service.refresh(.launch).value
    #expect(service[.codex].health.installation?.ownership == .nativeInstaller)
    await service.installUpdate(for: .codex).value

    #expect(try sandbox.read(cli.version) == "0.200.0\n")
    #expect(service[.codex].updateRun == .finished(.updated(to: CLIVersion(0, 200, 0))))
  }

  @Test func updatesSharingAPrefixWaitForEachOther() async throws {
    let sandbox = try Sandbox()
    let claude = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    let codex = try sandbox.versioned(Self.codexPackage, .codex, link: "npm/bin/codex")
    let log = sandbox.url("npm.log")
    try sandbox.script(
      "npm/bin/npm",
      """
      echo "start $5" >> '\(log.path)'
      sleep 0.3
      case "$5" in
        @anthropic-ai/*) echo 9.9.9 > '\(claude.version.path)' ;;
        @openai/*) echo 0.200.0 > '\(codex.version.path)' ;;
      esac
      echo "end $5" >> '\(log.path)'
      """)
    var environment = sandbox.environment()
    environment.latestVersions = { source in
      source.kind == .claude ? CLIVersion(9, 9, 9) : CLIVersion(0, 200, 0)
    }
    let service = AgentHealthService(defaults: sandbox.defaults, environment: environment)

    await service.refresh(.launch).value
    let first = service.installUpdate(for: .claude)
    let second = service.installUpdate(for: .codex)
    #expect(service[.claude].updateRun == .running)
    #expect(service[.codex].updateRun == .queued)
    #expect(service[.codex].updateRun.message == "Waiting for another update…")
    await first.value
    await second.value

    #expect(
      try sandbox.read(log)
        == "start @anthropic-ai/claude-code@latest\nend @anthropic-ai/claude-code@latest\n"
        + "start @openai/codex@latest\nend @openai/codex@latest\n")
    #expect(service[.claude].updateRun == .finished(.updated(to: CLIVersion(9, 9, 9))))
    #expect(service[.codex].updateRun == .finished(.updated(to: CLIVersion(0, 200, 0))))
  }

  @Test func aMovedInstallIsNotUpdated() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    let marker = sandbox.url("npm.ran")
    try sandbox.script("npm/bin/npm", "touch '\(marker.path)'")
    let service = sandbox.service()
    await service.refresh(.launch).value

    try FileManager.default.removeItem(at: cli.link)
    try sandbox.symlink("npm/bin/claude", to: try fake(.claude, .streamedReply))
    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .failed(.installationChanged))
    #expect(service[.claude].updateRun.message == "The install changed. Check again.")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    // The failure re-checks, so the row shows the copy that is there now and no offer loops on it.
    #expect(service[.claude].health.installation?.ownership == .unknown)
    #expect(service[.claude].updateOffer?.canStart != true)
  }

  @Test func aHomebrewUpdateMadeInTerminalRunsNothing() async throws {
    let sandbox = try Sandbox()
    let version = sandbox.url("codex.version")
    try sandbox.versioned(
      "brew/Cellar/codex/0.164.0/bin/codex", .codex, link: "brew/bin/codex", version: version)
    let marker = sandbox.url("brew.ran")
    try sandbox.script("brew/bin/brew", "touch '\(marker.path)'")
    let service = sandbox.service(latest: .success(CLIVersion(0, 200, 0)))
    await service.refresh(.launch).value

    // What `brew upgrade` leaves: a new keg, and the same link pointing at it.
    try Data("0.200.0\n".utf8).write(to: version)
    let newer = try sandbox.forwarder(
      "brew/Cellar/codex/0.200.0/bin/codex", to: sandbox.url("brew/Cellar/codex/0.164.0/bin/codex"))
    try FileManager.default.removeItem(at: sandbox.url("brew/bin/codex"))
    try sandbox.symlink("brew/bin/codex", to: newer)
    await service.installUpdate(for: .codex).value

    #expect(service[.codex].updateRun == .finished(.updated(to: CLIVersion(0, 200, 0))))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func aToolStoppedBySignalSaysSo() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "kill -9 $$")
    let service = sandbox.service()
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .failed(.crashed(tool: "npm", signal: 9)))
    #expect(service[.claude].updateRun.message == "npm stopped by signal 9.")
  }

  @Test func anUpdateMadeElsewhereRunsNothing() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    let marker = sandbox.url("npm.ran")
    try sandbox.script("npm/bin/npm", "touch '\(marker.path)'")
    let service = sandbox.service()
    await service.refresh(.launch).value

    try Data("9.9.9\n".utf8).write(to: cli.version)
    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .finished(.updated(to: CLIVersion(9, 9, 9))))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func anUnchangedVersionSaysSo() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "exit 0")
    let service = sandbox.service()
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .finished(.stillOutdated(CLIVersion(2, 1, 306))))
    #expect(service[.claude].updateRun.message == "Still on 2.1.306 after the update.")
    #expect(service[.claude].updateOffer?.canStart == true)
  }

  @Test func aVanishedCopyCannotBeVerified() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "rm '\(cli.target.path)'")
    let service = sandbox.service()
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .finished(.couldNotVerify))
    #expect(service[.claude].updateRun.message == "Couldn’t confirm the new version.")
    // No installation means no offer row, so Settings shows the line under the status instead.
    #expect(service[.claude].updateOffer == nil)
    #expect(service[.claude].updateRunWithoutOffer == .finished(.couldNotVerify))
  }

  @Test func aHungUpdateTimesOut() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "sleep 30")
    var timeouts = AgentEnvironment.Timeouts.unhurried
    timeouts.update = .milliseconds(300)
    let service = sandbox.service(timeouts: timeouts)
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .failed(.timedOut))
    #expect(service[.claude].updateRun.message == "Update timed out.")
  }

  @Test func aFailedUpdateShowsTheLastErrorLine() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script(
      "npm/bin/npm",
      """
      echo working
      printf '\\033[31mnpm error code E404\\033[0m\\n' >&2
      echo 'npm error 404 Not Found' >&2
      echo >&2
      exit 1
      """)
    let service = sandbox.service()
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun.message == "npm exited with code 1: npm error 404 Not Found")
    #expect(service[.claude].updateOffer?.isProblem == true)
  }

  @Test func aMissingNpmIsReported() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    let service = sandbox.service()
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun.message == "Couldn’t find npm.")
  }

  @Test func npmIsAlsoFoundInTheSearchDirectories() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("tools/npm", "echo 9.9.9 > '\(cli.version.path)'")
    let service = sandbox.service(directories: [sandbox.url("tools")])
    await service.refresh(.launch).value

    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .finished(.updated(to: CLIVersion(9, 9, 9))))
  }

  @Test func aLatestVersionBelowTheMinimumCannotBeInstalled() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude", version: "2.1.200")
    let marker = sandbox.url("npm.ran")
    try sandbox.script("npm/bin/npm", "touch '\(marker.path)'")
    let service = sandbox.service(latest: .success(CLIVersion(2, 1, 250)))
    await service.refresh(.launch).value

    let offer = try #require(service[.claude].updateOffer)
    #expect(offer.refusal == .latestBelowMinimum(CLIVersion(2, 1, 250)))
    #expect(offer.message == "The latest version, 2.1.250, is too old for OpenVocally.")
    #expect(!offer.canStart)
    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .idle)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test(arguments: [CLIVersion(2, 1, 200), CLIVersion(2, 1, 100)])
  func anUnsupportedVersionWithNoNewerLatestCannotBeClicked(_ latest: CLIVersion) async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude", version: "2.1.200")
    let marker = sandbox.url("npm.ran")
    try sandbox.script("npm/bin/npm", "touch '\(marker.path)'")
    let service = sandbox.service(latest: .success(latest))
    await service.refresh(.launch).value

    #expect(service[.claude].update == .current)
    let offer = try #require(service[.claude].updateOffer)
    #expect(offer.latest == latest)
    #expect(offer.refusal == .latestBelowMinimum(latest))
    #expect(!offer.canStart)
    await service.installUpdate(for: .claude).value

    #expect(service[.claude].updateRun == .idle)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func anUnsupportedVersionOffersTheUpdateBeforeTheLatestIsKnown() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude", version: "2.1.200")
    let service = sandbox.service(latest: .failure(TestFetchError()))
    await service.refresh(.launch).value

    let offer = try #require(service[.claude].updateOffer)
    #expect(offer.latest == nil)
    #expect(offer.canStart)
  }

  @Test func aSecondCallJoinsTheFirst() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    let log = sandbox.url("npm.log")
    try sandbox.script(
      "npm/bin/npm", "echo ran >> '\(log.path)'\nsleep 0.3\necho 9.9.9 > '\(cli.version.path)'")
    let service = sandbox.service()
    await service.refresh(.launch).value

    let first = service.installUpdate(for: .claude)
    let second = service.installUpdate(for: .claude)
    #expect(first == second)
    await first.value
    await service.installUpdate(for: .claude).value

    #expect(try sandbox.read(log) == "ran\n")
  }

  @Test func noSessionStartsWhileAnUpdateRuns() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "sleep 0.5\necho 9.9.9 > '\(cli.version.path)'")
    let service = sandbox.service()
    await service.refresh(.launch).value
    #expect(throws: Never.self) { try service.launchCommand(for: .claude) }

    let task = service.installUpdate(for: .claude)
    #expect(throws: LaunchCommandError.updating) { try service.launchCommand(for: .claude) }
    await service.refresh(.sessionFailed).value
    #expect(service[.claude].updateRun.isActive == false)
    await task.value

    #expect(throws: Never.self) { try service.launchCommand(for: .claude) }
  }

  @Test func aConfigurationChangeDuringAnUpdateIsReplayedAfterIt() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "sleep 0.3\necho 9.9.9 > '\(cli.version.path)'")
    let service = sandbox.service()
    await service.refresh(.launch).value

    let task = service.installUpdate(for: .claude)
    // npm is in its sleep by now, so the run itself goes on to the end.
    try await Task.sleep(for: .milliseconds(150))
    service.setEnabled(false, for: .claude)
    #expect(service[.claude].updateRun == .running)
    await task.value
    while service[.claude].health != .disabled { try await Task.sleep(for: .milliseconds(10)) }

    #expect(service[.claude].update == .unknown)
    // The run finished, but its outcome belongs to an install no longer shown.
    #expect(service[.claude].updateRun == .idle)
    #expect(try sandbox.read(cli.version) == "9.9.9\n")
  }

  @Test func aChosenPathChangeDuringAnUpdateEndsItWithoutAnOutcome() async throws {
    let sandbox = try Sandbox()
    let cli = try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.script("npm/bin/npm", "sleep 0.3\necho 9.9.9 > '\(cli.version.path)'")
    let other = try sandbox.forwarder("other/claude", to: fake(.claude, .streamedReply))
    let service = sandbox.service()
    await service.refresh(.launch).value

    let task = service.installUpdate(for: .claude)
    service.setChosenPath(other, for: .claude)
    await task.value
    #expect(service[.claude].updateRun == .idle)
    while service[.claude].health.installation?.path != other {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(service[.claude].health.installation?.ownership == .unknown)
    #expect(service[.claude].updateRun == .idle)
  }

  @Test func theNoticeCoversEveryProviderAndReturnsForANewerVersion() async throws {
    let sandbox = try Sandbox()
    try sandbox.versioned(Self.claudePackage, .claude, link: "npm/bin/claude")
    try sandbox.versioned(Self.codexPackage, .codex, link: "npm/bin/codex")
    let service = sandbox.service()
    await service.refresh(.launch).value

    let both = try #require(service.updateNotice)
    #expect(both.title == "Updates Available")
    #expect(both.detail == "Claude Code and Codex")
    #expect(both.firstKind == .claude)
    #expect(AgentUpdateNotice([]) == nil)
    service.dismiss(both)
    #expect(service.updateNotice == nil)
    let relaunched = sandbox.service()
    await relaunched.refresh(.launch).value
    #expect(relaunched.updateNotice == nil)

    sandbox.clock.advance(4 * 3600 + 1)
    let newer = sandbox.service(latest: .success(CLIVersion(10, 0, 0)))
    newer.setEnabled(false, for: .codex)
    await newer.refresh(.launch).value
    let one = try #require(newer.updateNotice)
    #expect(one.title == "Update Available")
    #expect(one.detail == "Claude Code 10.0.0")
  }

  @Test func theTailWindowKeepsTheEndOfALongOutput() async throws {
    let sandbox = try Sandbox()
    let script = try sandbox.script("loud", "i=0\nwhile [ $i -lt 3000 ]; do echo line $i; i=$((i+1)); done")
    let result = await Subprocess.run(
      script, [], environment: [:], timeout: .seconds(30), output: .tail(64))
    #expect(result.stdout.utf8.count == 64)
    #expect(result.stdout.hasSuffix("line 2999\n"))
    #expect(CLIUpdate.lastLine(result.stdout) == "line 2999")
  }
}

struct VersionedCLI {
  /// The file that runs, inside the package layout.
  let target: URL
  /// The symlink a user would have on PATH; configured as the chosen path.
  let link: URL
  /// What `--version` prints. Write to it to "update" the CLI.
  let version: URL
}

extension Sandbox {
  /// A CLI at `relativePath` that answers `--version` from a file and hands everything else to the
  /// fake, reached through a symlink at `link` the way npm and Homebrew link into `bin`.
  @discardableResult
  func versioned(
    _ relativePath: String, _ kind: AgentKind, link: String, before: String = "",
    version: String? = nil
  ) throws -> VersionedCLI {
    try versioned(
      relativePath, kind, link: link, before: before, version: url("\(kind.rawValue).version"),
      initial: version)
  }

  @discardableResult
  func versioned(
    _ relativePath: String, _ kind: AgentKind, link: String, before: String = "", version: URL,
    initial: String? = nil
  ) throws -> VersionedCLI {
    let start = initial ?? (kind == .claude ? "2.1.306" : "0.164.0")
    try Data("\(start)\n".utf8).write(to: version)
    let target = try script(
      relativePath,
      """
      \(before)
      if [ "$1" = --version ]; then cat '\(version.path)'; exit 0; fi
      exec '\(try fake(kind, .streamedReply).path)' "$@"
      """)
    let linked = try symlink(link, to: target)
    configure(kind, path: linked)
    return VersionedCLI(target: target, link: linked, version: version)
  }

  func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}
