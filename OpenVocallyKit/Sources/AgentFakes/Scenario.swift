/// The persona a fake binary plays. The raw value is the executable's file name.
package enum Provider: String, CaseIterable, Sendable, Hashable {
  case claude
  case codex
}

/// The raw value is the install directory name. The binary reads its scenario from its own path,
/// because the host owns argv and the environment.
package enum ScenarioID: String, CaseIterable, Sendable, Hashable {
  case streamedReply = "streamed-reply"
  case commandApproval = "command-approval"
  case fileApproval = "file-approval"
  case chromeSiteApproval = "chrome-site-approval"
  case computerUseApproval = "computer-use-approval"
  case agentQuestion = "agent-question"
  case mcpForm = "mcp-form"
  case mcpSignIn = "mcp-sign-in"
  case crashMidTurn = "crash-mid-turn"
  case loggedOut = "logged-out"
  case belowMinimumVersion = "below-minimum-version"
  case lostSession = "lost-session"
  case selfStartedTurn = "self-started-turn"
  /// Health only: the login check fails in a way the host cannot read.
  case needsAttention = "needs-attention"
}

package enum HealthProfile: Sendable, Hashable {
  case available
  case loggedOut
  case belowMinimumVersion
  case needsAttention
}

package enum ResumeBehavior: Sendable, Hashable {
  case resumes
  /// The transcript is gone, so resuming fails the way the real CLI does.
  case sessionLost
}

/// A scripted session. Pure data: `SessionEngine` interprets it and a `Wire` encodes it.
package struct Scenario: Sendable {
  package let id: ScenarioID
  package let providers: Set<Provider>
  package let health: HealthProfile
  package let resume: ResumeBehavior
  /// `nil` for a health-only scenario, which refuses to start a session.
  package let script: [Beat]?

  package static var all: [Scenario] { ScenarioID.allCases.map(named) }

  package static func named(_ id: ScenarioID) -> Scenario {
    let both: Set<Provider> = [.claude, .codex]
    func session(_ script: [Beat], only providers: Set<Provider> = both) -> Scenario {
      Scenario(id: id, providers: providers, health: .available, resume: .resumes, script: script)
    }
    switch id {
    case .streamedReply:
      return session([
        .awaitUserTurn, .stream("Here is a streamed reply in three parts.", chunks: 3), .completeTurn,
      ])
    case .commandApproval:
      return session([
        .awaitUserTurn,
        .stream("I'll build the project.", chunks: 1),
        .ask(
          .command("swift build", workingDirectory: "/tmp/fake-project"),
          approved: [.stream("Build succeeded.", chunks: 1)],
          declined: [.stream("Okay, I won't run it.", chunks: 1)]),
        .completeTurn,
      ])
    case .fileApproval:
      return session([
        .awaitUserTurn,
        .ask(
          .fileChange(path: "/tmp/fake-project/README.md", oldText: "# Fake", newText: "# Fake\n\n## Usage"),
          approved: [.stream("Updated README.md.", chunks: 1)],
          declined: [.stream("Left README.md as it was.", chunks: 1)]),
        .completeTurn,
      ])
    case .chromeSiteApproval:
      return session(
        [
          .awaitUserTurn,
          .ask(
            .chromeSite(domain: "example.com", url: "https://example.com/pricing"),
            approved: [.stream("The pricing page lists three plans.", chunks: 1)],
            declined: [.stream("I won't open that site.", chunks: 1)]),
          .completeTurn,
        ], only: [.claude])
    case .computerUseApproval:
      return session(
        [
          .awaitUserTurn,
          .ask(
            .computerUse(app: "Finder"),
            approved: [.stream("Opened Finder.", chunks: 1)],
            declined: [.stream("I won't control Finder.", chunks: 1)]),
          .completeTurn,
        ], only: [.codex])
    case .agentQuestion:
      return session(
        [
          .awaitUserTurn,
          .ask(
            .question(
              header: "Target", question: "Which branch should I merge into?", options: ["main", "release"]),
            approved: [.echoAnswer(prefix: "Merging into ")],
            declined: [.stream("Okay, I'll stop here.", chunks: 1)]),
          .completeTurn,
        ], only: [.claude])
    case .mcpForm:
      return session([
        .awaitUserTurn,
        .ask(
          .mcpForm(
            server: "tickets", message: "Create a ticket",
            fields: [.init(name: "title", title: "Title", required: true)]),
          approved: [.echoAnswer(prefix: "Created ticket: ")],
          declined: [.stream("No ticket created.", chunks: 1)]),
        .completeTurn,
      ])
    case .mcpSignIn:
      return session([
        .awaitUserTurn,
        .ask(
          .mcpSignIn(server: "tickets", url: "https://auth.example.com/authorize?client=fake"),
          approved: [.stream("Signed in to tickets.", chunks: 1)],
          declined: [.stream("Sign-in cancelled.", chunks: 1)]),
        .completeTurn,
      ])
    case .crashMidTurn:
      return session([
        .awaitUserTurn, .stream("Starting the work and then", chunks: 2),
        .crash(exitCode: 1, stderr: "fake: simulated crash mid-turn"),
      ])
    case .loggedOut:
      return Scenario(
        id: id, providers: both, health: .loggedOut, resume: .resumes,
        script: [.awaitUserTurn, .failTurn(.notLoggedIn)])
    case .belowMinimumVersion:
      // The session works: the host must refuse it from health, not from a broken stream.
      return Scenario(
        id: id, providers: both, health: .belowMinimumVersion, resume: .resumes,
        script: [.awaitUserTurn, .stream("Old version reply.", chunks: 1), .completeTurn])
    case .lostSession:
      return Scenario(
        id: id, providers: both, health: .available, resume: .sessionLost,
        script: [.awaitUserTurn, .stream("Fresh session reply.", chunks: 1), .completeTurn])
    case .selfStartedTurn:
      return session(
        [
          .awaitUserTurn, .stream("Started the background check.", chunks: 1), .completeTurn,
          .selfStartTurn, .stream("Background check finished: all green.", chunks: 2), .completeTurn,
        ], only: [.claude])
    case .needsAttention:
      return Scenario(id: id, providers: both, health: .needsAttention, resume: .resumes, script: nil)
    }
  }
}
