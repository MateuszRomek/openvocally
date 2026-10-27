import AgentFakes
import Foundation
import Testing

@testable import Agents

struct HealthRow: Sendable, CustomTestStringConvertible {
  let kind: AgentKind
  let scenario: ScenarioID
  let status: HealthStatus
  let version: String
  let signIn: SignIn?

  var testDescription: String { "\(kind.rawValue) \(scenario.rawValue) → \(status.rawValue)" }
}

@MainActor
struct HealthTests {
  nonisolated static let rows: [HealthRow] = [
    HealthRow(
      kind: .claude, scenario: .streamedReply, status: .available, version: "2.1.306",
      signIn: .signedIn(method: "Claude account")),
    HealthRow(
      kind: .claude, scenario: .loggedOut, status: .notAuthenticated, version: "2.1.306", signIn: .signedOut),
    HealthRow(
      kind: .claude, scenario: .belowMinimumVersion, status: .unsupportedVersion, version: "2.1.200",
      signIn: nil),
    HealthRow(
      kind: .claude, scenario: .needsAttention, status: .couldntConfirmSignIn, version: "2.1.306",
      signIn: .unconfirmed(.unreadable)),
    HealthRow(
      kind: .codex, scenario: .streamedReply, status: .available, version: "0.164.0-alpha.11.1",
      signIn: .signedIn(method: "ChatGPT")),
    HealthRow(
      kind: .codex, scenario: .loggedOut, status: .notAuthenticated, version: "0.164.0-alpha.11.1",
      signIn: .signedOut),
    HealthRow(
      kind: .codex, scenario: .belowMinimumVersion, status: .unsupportedVersion, version: "0.150.0",
      signIn: nil),
    HealthRow(
      kind: .codex, scenario: .needsAttention, status: .couldntConfirmSignIn, version: "0.164.0-alpha.11.1",
      signIn: .unconfirmed(.unreadable)),
  ]

  @Test(arguments: rows)
  func everyFakeScenarioHasItsStatus(_ row: HealthRow) async throws {
    let sandbox = try Sandbox()
    let path = try fake(row.kind, row.scenario)
    sandbox.configure(row.kind, path: path)
    let service = sandbox.service()
    #expect(service[row.kind].health == .checking)

    await service.refresh(.launch).value

    let health = service[row.kind].health
    #expect(health.status == row.status)
    #expect(health.installation?.version.description == row.version)
    #expect(health.installation?.path == path)
    #expect(health.installation?.origin == .chosen)
    #expect(health.signIn == row.signIn)
    #expect(health.skipped.isEmpty)
    #expect(health.blocksUse == [.notAuthenticated, .unsupportedVersion].contains(row.status))
    #expect(service[row.kind == .claude ? .codex : .claude].health == .disabled)
    #expect(service[row.kind].update == .unknown)
    #expect(sandbox.fetches.value == 0)
  }

  @Test(
    arguments: [
      ("Logged in using ChatGPT", "ChatGPT"),
      ("Logged in using an API key - sk-proj-***ABCD", "API key"),
      ("Logged in using personal access token", "access token"),
      ("Logged in using someone@example.com via SSO", nil),
    ] as [(String, String?)])
  func codexSignInShowsOnlyAFixedLabel(_ line: String, _ label: String?) {
    let result = ProbeResult(ending: .exited(0), stdout: "", stderr: line + "\n")
    #expect(SignInParser.codex(result) == .signedIn(method: label))
  }

  @Test func anUnsupportedVersionWithNoUpdateCommandSaysHowToUpdate() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(.claude, path: try fake(.claude, .belowMinimumVersion))
    let service = sandbox.service()

    await service.refresh(.launch).value

    let health = service[.claude].health
    #expect(health.installation?.ownership == .unknown)
    #expect(service[.claude].updateOffer == nil)
    #expect(
      health.detail(for: .claude)
        == "Version 2.1.200 is older than 2.1.268. Update it the way you installed it.")
  }

  @Test func anUnsupportedVersionWithAnUpdateCommandKeepsItsWording() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(
      .claude,
      path: try sandbox.forwarder(
        "Caskroom/claude-code/2.1.200/claude", to: fake(.claude, .belowMinimumVersion)))
    let service = sandbox.service()

    await service.refresh(.launch).value

    let health = service[.claude].health
    let installation = try #require(health.installation)
    #expect(service[.claude].updateOffer != nil)
    let recipe = try #require(UpdateRecipe(installation, spec: AgentKind.claude.spec))
    #expect(recipe.arguments == ["upgrade", "--cask", "claude-code"])
    #expect(health.detail(for: .claude) == "Version 2.1.200 is older than 2.1.268. Update to use it.")
  }

  @Test func danglingSymlinkAheadOfAWorkingCopyIsSkippedWithANote() async throws {
    let sandbox = try Sandbox()
    let dangling = try sandbox.symlink("first/claude", to: sandbox.url("gone/claude"))
    let working = try sandbox.symlink("second/claude", to: fake(.claude, .streamedReply))
    sandbox.configure(.claude)
    let service = sandbox.service(directories: [sandbox.url("first"), sandbox.url("second")])

    await service.refresh(.launch).value

    let health = service[.claude].health
    #expect(health.status == .available)
    #expect(health.installation?.path == working)
    #expect(health.installation?.origin == .loginShellPath)
    #expect(
      health.skipped == [SkippedCopy(path: dangling, origin: .loginShellPath, reason: .danglingSymlink)])
    #expect(health.skipped.first?.note == "Skipped \(dangling.path): the link points nowhere.")
  }

  @Test func onlyDanglingLinksAreNotFound() async throws {
    let sandbox = try Sandbox()
    try sandbox.symlink("bin/claude", to: sandbox.url("gone/claude"))
    sandbox.configure(.claude)
    let service = sandbox.service(directories: [sandbox.url("bin")])

    await service.refresh(.launch).value

    #expect(service[.claude].health.status == .notFound)
    #expect(service[.claude].health.skipped.map(\.reason) == [.danglingSymlink])
  }

  @Test func filesOnDiskThatDoNotRunNeedAttention() async throws {
    let sandbox = try Sandbox()
    let plain = sandbox.url("a/claude")
    try FileManager.default.createDirectory(
      at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a program".utf8).write(to: plain)
    let failing = try sandbox.script("b/claude", "exit 3")
    let silent = try sandbox.script("c/claude", "exit 0")
    sandbox.configure(.claude)
    let service = sandbox.service(directories: ["a", "b", "c"].map(sandbox.url))

    await service.refresh(.launch).value

    let health = service[.claude].health
    #expect(health.status == .needsAttention)
    #expect(
      health.skipped == [
        SkippedCopy(path: plain, origin: .loginShellPath, reason: .notExecutable),
        SkippedCopy(path: failing, origin: .loginShellPath, reason: .failedToRun(exitCode: 3)),
        SkippedCopy(path: silent, origin: .loginShellPath, reason: .unreadableVersion),
      ])
  }

  @Test func nothingOnDiskIsNotFound() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(.codex, path: sandbox.url("deleted/codex"))
    let service = sandbox.service(directories: [sandbox.url("empty")])

    await service.refresh(.launch).value

    let health = service[.codex].health
    #expect(
      health
        == .notFound(skipped: [
          SkippedCopy(path: sandbox.url("deleted/codex"), origin: .chosen, reason: .missing)
        ]))
  }

  @Test func aVersionThatHangsTimesOutWithoutBlockingTheMainActor() async throws {
    let sandbox = try Sandbox()
    let hang = try sandbox.script("hang/claude", "sleep 600")
    sandbox.configure(.claude, path: hang)
    let service = sandbox.service(timeouts: .init(version: .seconds(1)))
    let ticker = Ticker()
    ticker.start()
    let started = ContinuousClock.now

    await service.refresh(.launch).value

    let elapsed = ContinuousClock.now - started
    ticker.stop()
    #expect(
      service[.claude].health
        == .needsAttention(skipped: [SkippedCopy(path: hang, origin: .chosen, reason: .timedOut)]))
    #expect(elapsed < .seconds(10), "timed out instead of waiting for the 600 s hang")
    #expect(ticker.longestGap < .seconds(1), "the main actor was never held for the 1 s probe")
  }

  @Test func aSignInThatHangsCannotBeConfirmedAndDoesNotBlock() async throws {
    let sandbox = try Sandbox()
    let stub = try sandbox.script(
      "hang/claude", "if [ \"$1\" = --version ]; then echo '2.1.306 (Claude Code)'; exit 0; fi\nsleep 600")
    sandbox.configure(.claude, path: stub)
    let service = sandbox.service(timeouts: .init(signIn: .seconds(1)))

    await service.refresh(.launch).value

    let health = service[.claude].health
    #expect(health.status == .couldntConfirmSignIn)
    #expect(health.signIn == .unconfirmed(.timedOut))
    #expect(!health.blocksUse)
  }

  @Test func aRecheckKeepsTheLastResultOnScreen() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(.claude, path: try fake(.claude, .streamedReply))
    let service = sandbox.service()
    await service.refresh(.launch).value

    let again = service.refresh(.sessionFailed)
    #expect(service[.claude].health.status == .available)
    await again.value
    #expect(service[.claude].health.status == .available)
  }

  @Test func aConfigurationChangeDropsTheSupersededResult() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(.claude, path: try sandbox.script("hang/claude", "sleep 600"))
    let service = sandbox.service()
    let first = service.refresh(.launch)

    service.setChosenPath(try fake(.claude, .streamedReply), for: .claude)
    #expect(service[.claude].health == .checking)
    await service.refresh(.launch).value
    await first.value

    #expect(service[.claude].health.status == .available)
    #expect(
      ProviderConfiguration.load(.claude, from: sandbox.defaults).chosenPath
        == (try fake(.claude, .streamedReply)))
  }

  @Test func activationIsThrottledPerProvider() async throws {
    let sandbox = try Sandbox()
    let marker = sandbox.url("runs")
    let stub = try sandbox.script(
      "bin/claude", "echo run >> '\(marker.path)'\nexec '\(try fake(.claude, .streamedReply).path)' \"$@\"")
    sandbox.configure(.claude, path: stub)
    let service = sandbox.service()
    await service.refresh(.launch).value
    let afterLaunch = try String(contentsOf: marker, encoding: .utf8).count

    await service.refresh(.appActivated).value
    #expect(try String(contentsOf: marker, encoding: .utf8).count == afterLaunch)

    sandbox.clock.advance(AgentHealthService.activationThrottle + 1)
    await service.refresh(.appActivated).value
    #expect(try String(contentsOf: marker, encoding: .utf8).count > afterLaunch)
  }

  @Test func aSessionFailureDuringASlowUpdateCheckProbesAgain() async throws {
    let sandbox = try Sandbox()
    let marker = sandbox.url("runs")
    let stub = try sandbox.script(
      "Caskroom/claude-code/2.1.306/claude",
      "echo run >> '\(marker.path)'\nexec '\(try fake(.claude, .streamedReply).path)' \"$@\"")
    sandbox.configure(.claude, path: stub)
    var environment = sandbox.environment()
    environment.latestVersions = { _ in
      try await Task.sleep(for: .seconds(1))
      return CLIVersion(9, 9, 9)
    }
    let service = AgentHealthService(defaults: sandbox.defaults, environment: environment)
    let launch = service.refresh(.launch)
    while service[.claude].health == .checking { try await Task.sleep(for: .milliseconds(10)) }
    let afterLaunch = try String(contentsOf: marker, encoding: .utf8).count

    await service.refresh(.sessionFailed).value

    #expect(try String(contentsOf: marker, encoding: .utf8).count > afterLaunch)
    #expect(service[.claude].health.status == .available)
    await launch.value
    #expect(
      service[.claude].update
        == .available(latest: CLIVersion(9, 9, 9)))
  }

  @Test func settingsShownIsThrottledPerProvider() async throws {
    let sandbox = try Sandbox()
    let marker = sandbox.url("runs")
    let stub = try sandbox.script(
      "bin/claude", "echo run >> '\(marker.path)'\nexec '\(try fake(.claude, .streamedReply).path)' \"$@\"")
    sandbox.configure(.claude, path: stub)
    let service = sandbox.service()
    func runs() throws -> Int { try String(contentsOf: marker, encoding: .utf8).count }

    await service.refresh(.settingsShown).value
    let afterFirst = try runs()
    #expect(afterFirst > 0)

    sandbox.clock.advance(AgentHealthService.activationThrottle - 1)
    await service.refresh(.settingsShown).value
    #expect(try runs() == afterFirst)

    sandbox.clock.advance(2)
    await service.refresh(.settingsShown).value
    #expect(try runs() > afterFirst)
  }

  @Test func launchCommandSplitsTheArgumentsAndNeverBuildsAShellString() async throws {
    let sandbox = try Sandbox()
    let path = try fake(.claude, .streamedReply)
    sandbox.configure(.claude, path: path, arguments: "--chrome \"a b\" $HOME;rm")
    let service = sandbox.service()
    await service.refresh(.launch).value

    #expect(
      try service.launchCommand(for: .claude)
        == LaunchCommand(executable: path, arguments: ["--chrome", "a b", "$HOME;rm"]))

    service.setLaunchArguments("\"oops", for: .claude)
    #expect(throws: LaunchCommandError.arguments(.unterminatedQuote(offset: 0))) {
      try service.launchCommand(for: .claude)
    }
    #expect(throws: LaunchCommandError.disabled) { try service.launchCommand(for: .codex) }
  }

  @Test func launchCommandThrowsWhenHealthBlocksUse() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(.codex, path: try fake(.codex, .loggedOut))
    let service = sandbox.service()
    #expect(throws: LaunchCommandError.blocked(.checking)) { try service.launchCommand(for: .codex) }

    await service.refresh(.launch).value

    #expect(throws: LaunchCommandError.blocked(.notAuthenticated)) { try service.launchCommand(for: .codex) }
    #expect(service[.codex].health.signIn == .signedOut)
  }
}
