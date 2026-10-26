import AgentFakes
import AgentFakesTestSupport
import Foundation
import Testing

struct FakeCase: Sendable, CustomTestStringConvertible {
  let scenario: ScenarioID
  let provider: Provider
  let choice: HostChoice
  var testDescription: String { "\(provider.rawValue) \(scenario.rawValue) \(choice.rawValue)" }

  /// Every session scenario with every host choice that applies, for each provider that plays it.
  static var all: [FakeCase] {
    Scenario.all.filter { $0.script != nil }.flatMap { scenario in
      Provider.allCases.filter(scenario.providers.contains).flatMap { provider in
        choices(scenario, provider).map { FakeCase(scenario: scenario.id, provider: provider, choice: $0) }
      }
    }
  }

  private static func choices(_ scenario: Scenario, _ provider: Provider) -> [HostChoice] {
    let stdio: [HostChoice] = provider == .claude ? [.answerOnStdio, .declineOnStdio, .interruptOnStdio] : []
    switch asks(scenario.script ?? []).first {
    case .command?, .fileChange?, .chromeSite?, .computerUse?:
      return [.approve, .approveForSession, .decline, .interrupt] + stdio
    case .question?, .mcpForm?, .mcpSignIn?:
      return [.approve, .decline, .interrupt] + stdio
    case .mcpUnknownMode?:
      return [.decline, .interrupt]
    case nil:
      switch scenario.id {
      case .streamedReply:
        return provider == .claude ? [.main, .resume, .plainOutput, .idleControl] : [.main, .resume]
      case .lostSession: return [.main, .resume]
      default: return [.main]
      }
    }
  }
}

func asks(_ beats: [Beat]) -> [Ask] {
  beats.flatMap { beat -> [Ask] in
    guard case .ask(let ask, let approved, let declined) = beat else { return [] }
    return [ask] + asks(approved) + asks(declined)
  }
}

struct FakeAgentTests {
  @Test(arguments: FakeCase.all)
  func `plays the scripted session`(_ c: FakeCase) async throws {
    let transcript = try #require(
      Transcripts.expected(for: c.scenario, provider: c.provider, choice: c.choice))
    try await FakeHost.play(transcript, as: c.provider, c.scenario, fakes: FakeAgents.shared())
  }

  @Test(arguments: ClaudeEdge.allCases)
  func `Claude answers host input outside the choice matrix`(_ edge: ClaudeEdge) async throws {
    try await FakeHost.play(
      Transcripts.expected(for: edge), as: .claude, .commandApproval, fakes: FakeAgents.shared())
  }

  @Test(arguments: CodexEdge.allCases)
  func `Codex refuses host requests outside the contract`(_ edge: CodexEdge) async throws {
    try await FakeHost.play(
      Transcripts.expected(for: edge), as: .codex, edge.scenario, fakes: FakeAgents.shared())
  }

  @Test func `a transcript that does not end with an exit fails`() async throws {
    let fakes = try FakeAgents.shared()
    await withKnownIssue {
      try await FakeHost.play(HostTranscript(moves: [.closeInput]), as: .claude, .streamedReply, fakes: fakes)
    }
  }

  @Test(arguments: FakeCase.all.filter { $0.choice == .main || $0.choice == .approve })
  func `writes the same bytes on every run`(_ c: FakeCase) async throws {
    let transcript = try #require(
      Transcripts.expected(for: c.scenario, provider: c.provider, choice: c.choice))
    let first = try await FakeHost.play(transcript, as: c.provider, c.scenario, fakes: FakeAgents.shared())
    let second = try await FakeHost.play(transcript, as: c.provider, c.scenario, fakes: FakeAgents.shared())
    #expect(!first.isEmpty)
    #expect(first == second)
  }

  @Test(arguments: Provider.allCases, Scenario.all.map(\.id))
  func `a scenario lists a provider exactly when its wire encodes the scenario's asks`(
    _ provider: Provider, _ id: ScenarioID
  ) {
    let scenario = Scenario.named(id)
    guard let script = scenario.script, !asks(script).isEmpty else { return }
    #expect(scenario.providers.contains(provider) == asks(script).allSatisfy(provider.encodes))
  }

  @Test(arguments: Provider.allCases, ScenarioID.allCases)
  func `answers health from the measured table`(_ provider: Provider, _ id: ScenarioID) throws {
    let path = try FakeAgents.shared().path(provider, id)
    let scenario = Scenario.named(id)
    guard scenario.providers.contains(provider) else {
      #expect(!FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
      return
    }
    for (arguments, expected) in HealthTable.expected(provider, scenario.health) {
      let got = try ProcessRun.run(path, arguments)
      #expect(got.exitCode == expected.exitCode, "\(arguments)")
      #expect(got.stdout == expected.stdout, "\(arguments)")
      #expect(got.stderr == expected.stderr, "\(arguments)")
    }
  }

  @Test(arguments: [
    (["--settings", "{}"], Int32(2), "missing -p"),
    (["-p", "--output-format", "stream-json"], 1, "requires --verbose"),
    (
      [
        "-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--session-id",
        "x",
        "--settings", "{}", "--permission-mode", "default",
      ], 2, "--permission-prompt-tool stdio"
    ),
    (
      [
        "-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--session-id",
        FakeHost.sessionID, "--settings", "{}", "--permission-mode", "yolo", "--permission-prompt-tool",
        "stdio",
      ], 1, "Allowed choices are default, acceptEdits, auto, bypassPermissions, dontAsk, plan"
    ),
    (
      [
        "-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--session-id",
        "x", "--settings", "{}", "--permission-mode", "default", "--permission-prompt-tool", "stdio",
      ], 1, "Must be a valid UUID"
    ),
  ])
  func `Claude refuses a launch that breaks the contract`(
    _ arguments: [String], _ code: Int32, _ message: String
  )
    throws
  {
    let got = try ProcessRun.run(FakeAgents.shared().path(.claude, .streamedReply), arguments)
    #expect(got.exitCode == code)
    #expect(got.stderr.contains(message))
    #expect(got.stdout.isEmpty)
  }

  @Test func `a health-only scenario refuses a session`() throws {
    let got = try ProcessRun.run(FakeAgents.shared().path(.claude, .needsAttention), ["-p"])
    #expect(got.exitCode == 2)
    #expect(got.stderr.contains("only answers health"))
  }

  /// Global options may come before the subcommand; a value that reads `app-server` is still a value.
  static let codexLaunches: [([String], Int32)] = [
    (["app-server"], 0), (["-c", "k=v", "--enable", "f", "app-server"], 0),
    (["--config", "k=v", "--disable", "f", "-p", "work", "--profile", "work", "app-server"], 0),
    (["exec"], 2), (["exec", "app-server"], 2), (["-c", "app-server"], 2), (["--enable", "app-server"], 2),
  ]

  @Test(arguments: codexLaunches)
  func `Codex needs app-server as the first argument that is not an option`(
    _ arguments: [String], _ code: Int32
  ) throws {
    let got = try ProcessRun.run(FakeAgents.shared().path(.codex, .streamedReply), arguments)
    #expect(got.exitCode == code)
    #expect(got.stderr.contains("missing the app-server subcommand") == (code != 0))
    #expect(got.stdout.isEmpty)
  }
}

/// Literal answers, independent of `HealthAnswer`.
enum HealthTable {
  typealias Answer = (stdout: String, stderr: String, exitCode: Int32)

  static func expected(_ provider: Provider, _ profile: HealthProfile) -> [([String], Answer)] {
    let claudeIn =
      "{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\",\n  \"apiProvider\": \"firstParty\"\n}\n"
    let claudeOut =
      "{\n  \"loggedIn\": false,\n  \"authMethod\": \"none\",\n  \"apiProvider\": \"firstParty\"\n}\n"
    let unreadable: Answer = ("", "Error: could not read credentials\n", 2)
    switch (provider, profile) {
    case (.claude, .available):
      return [
        (["--version"], ("2.1.306 (Claude Code)\n", "", 0)), (["auth", "status"], (claudeIn, "", 0)),
        (["auth", "status", "--json"], (claudeIn, "", 0)),
        (
          ["auth", "status", "--text"],
          (
            "Login method: Claude Max account\nOrganization: Fake Organization\nEmail: fake@example.com\n"
              + "Anthropic base URL: https://api.anthropic.com\n", "", 0
          )
        ),
      ]
    case (.claude, .loggedOut):
      return [
        (["--version"], ("2.1.306 (Claude Code)\n", "", 0)), (["auth", "status"], (claudeOut, "", 1)),
        (["auth", "status", "--text"], ("Not logged in. Run claude auth login to authenticate.\n", "", 1)),
      ]
    case (.claude, .belowMinimumVersion):
      return [(["--version"], ("2.1.200 (Claude Code)\n", "", 0)), (["auth", "status"], (claudeIn, "", 0))]
    case (.claude, .needsAttention):
      return [(["--version"], ("2.1.306 (Claude Code)\n", "", 0)), (["auth", "status"], unreadable)]
    case (.codex, .available):
      return [
        (["--version"], ("codex-cli 0.164.0-alpha.11.1\n", "", 0)),
        (["login", "status"], ("", "Logged in using ChatGPT\n", 0)),
      ]
    case (.codex, .loggedOut):
      return [
        (["--version"], ("codex-cli 0.164.0-alpha.11.1\n", "", 0)),
        (["login", "status"], ("", "Not logged in\n", 1)),
      ]
    case (.codex, .belowMinimumVersion):
      return [
        (["--version"], ("codex-cli 0.150.0\n", "", 0)),
        (["login", "status"], ("", "Logged in using ChatGPT\n", 0)),
      ]
    case (.codex, .needsAttention):
      return [(["--version"], ("codex-cli 0.164.0-alpha.11.1\n", "", 0)), (["login", "status"], unreadable)]
    }
  }
}
