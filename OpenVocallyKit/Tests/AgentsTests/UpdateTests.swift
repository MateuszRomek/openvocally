import Foundation
import Synchronization
import Testing

@testable import Agents

@MainActor
struct UpdateTests {
  @Test func freshCacheMakesNoNetworkCallsForFourHours() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.forwarder("Caskroom/claude-code/2.1.306/claude", to: fake(.claude, .streamedReply))
    sandbox.configure(.claude, path: path)
    let service = sandbox.service()

    await service.refresh(.launch).value
    #expect(
      service[.claude].update
        == .available(latest: CLIVersion(9, 9, 9)))
    #expect(sandbox.fetches.value == 1)

    sandbox.clock.advance(3 * 3600)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 1)
    await sandbox.service().refresh(.launch).value
    #expect(sandbox.fetches.value == 1)

    sandbox.clock.advance(3600 + 1)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 2)
  }

  @Test func aFailedFetchIsRetriedAfterFifteenMinutes() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(
      .claude,
      path: try sandbox.forwarder("Caskroom/claude-code/2.1.306/claude", to: fake(.claude, .streamedReply)))
    let service = sandbox.service(latest: .failure(TestFetchError()))

    await service.refresh(.launch).value
    #expect(service[.claude].update == .unknown)
    sandbox.clock.advance(10 * 60)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 1)
    sandbox.clock.advance(6 * 60)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 2)
  }

  @Test func aFailedFetchKeepsTheLastKnownVersion() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(
      .claude,
      path: try sandbox.forwarder("Caskroom/claude-code/2.1.306/claude", to: fake(.claude, .streamedReply)))
    let fails = Atomic(false)
    var environment = sandbox.environment()
    let succeed = environment.latestVersions
    environment.latestVersions = { source in
      let result = try await succeed(source)
      if fails.load(ordering: .relaxed) { throw TestFetchError() }
      return result
    }
    let service = AgentHealthService(defaults: sandbox.defaults, environment: environment)
    let available = UpdateAdvisory.available(latest: CLIVersion(9, 9, 9))

    await service.refresh(.launch).value
    #expect(service[.claude].update == available)

    fails.store(true, ordering: .relaxed)
    sandbox.clock.advance(4 * 3600 + 1)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 2)
    #expect(service[.claude].update == available)

    sandbox.clock.advance(14 * 60)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 2)
    #expect(service[.claude].update == available)

    sandbox.clock.advance(2 * 60)
    await service.refresh(.sessionFailed).value
    #expect(sandbox.fetches.value == 3)
    #expect(service[.claude].update == available)
  }

  @Test func aDisabledProviderRunsNothingAndFetchesNothing() async throws {
    let sandbox = try Sandbox()
    let marker = sandbox.url("ran")
    let stub = try sandbox.script("Caskroom/claude-code/1/claude", "touch '\(marker.path)'")
    sandbox.configure(.claude, enabled: false, path: stub)
    let service = sandbox.service()

    await service.refresh(.launch).value
    await service.refresh(.settingsShown).value

    #expect(service[.claude].health == .disabled)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(sandbox.fetches.value == 0)
  }

  @Test func aBundledCopyUpdatesWithItsAppAndNeverFetches() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(
      .codex,
      path: try sandbox.forwarder(
        "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", to: fake(.codex, .streamedReply)))
    let service = sandbox.service()

    await service.refresh(.launch).value

    #expect(service[.codex].health.installation?.ownership == .bundled(appName: "ChatGPT"))
    #expect(service[.codex].update == .unknown)
    #expect(sandbox.fetches.value == 0)
  }

  @Test func aHomebrewNameOutsideTheAllowListIsUnknown() async throws {
    let sandbox = try Sandbox()
    sandbox.configure(
      .claude,
      path: try sandbox.forwarder("Caskroom/evil.example/1.0/claude", to: fake(.claude, .streamedReply)))
    let service = sandbox.service()

    await service.refresh(.launch).value

    #expect(service[.claude].health.installation?.ownership == .unknown)
    #expect(service[.claude].update == .unknown)
    #expect(sandbox.fetches.value == 0)
  }

  @Test(arguments: [
    (
      "lib/node_modules/@openai/codex/bin/codex", AgentKind.codex,
      "npm install -g --prefix <sandbox> @openai/codex@latest"
    ),
    ("Cellar/codex/0.164.0/bin/codex", .codex, "brew upgrade codex"),
    (".local/share/claude/versions/2.1.306", .claude, "claude update"),
  ])
  func ownershipPicksTheUpdateCommand(_ relativePath: String, _ kind: AgentKind, _ command: String)
    async throws
  {
    let sandbox = try Sandbox()
    let target = try sandbox.forwarder(relativePath, to: fake(kind, .streamedReply))
    sandbox.configure(kind, path: try sandbox.symlink("bin/\(kind.rawValue)", to: target))
    let service = sandbox.service()

    await service.refresh(.launch).value

    #expect(service[kind].update == .available(latest: CLIVersion(9, 9, 9)))
    let prefix = sandbox.directory.path(percentEncoded: false).trimmingCharacters(in: ["/"])
    let installation = try #require(service[kind].health.installation)
    let recipe = try #require(UpdateRecipe(installation, spec: kind.spec))
    #expect(service[kind].updateOffer?.canStart == true)
    #expect(
      ([recipe.toolName] + recipe.arguments).joined(separator: " ")
        == command.replacing("<sandbox>", with: "/" + prefix))
    #expect(sandbox.fetches.value == 1)
  }

  /// npm updates the prefix the CLI was found in, even one with a space, never the shell's npm.
  @Test func npmUpdatesTheInstallsOwnPrefix() throws {
    let prefix = URL(filePath: "/Users/a b/.npm-global")
    let installation = Installation(
      path: prefix.appending(path: "bin/codex"),
      resolved: prefix.appending(path: "lib/node_modules/@openai/codex/bin/codex.js"), origin: .chosen,
      ownership: .npm(package: "@openai/codex", prefix: prefix), version: CLIVersion(0, 164, 0))
    let recipe = try #require(UpdateRecipe(installation, spec: AgentKind.codex.spec))
    #expect(
      recipe.arguments == ["install", "-g", "--prefix", "/Users/a b/.npm-global", "@openai/codex@latest"])
  }

  @Test func versionsOrderBySemVer() {
    #expect(CLIVersion("0.164.0-alpha.11.1")! >= AgentSpec.codex.minimumVersion)
    #expect(CLIVersion("1.0.0-alpha")! < CLIVersion("1.0.0-alpha.1")!)
    #expect(CLIVersion("1.0.0-alpha.2")! < CLIVersion("1.0.0-alpha.11")!)
    #expect(CLIVersion("1.0.0-alpha.beta")! < CLIVersion("1.0.0")!)
    #expect(CLIVersion.firstToken(in: "codex-cli 0.162") == CLIVersion(0, 162, 0))
  }
}
