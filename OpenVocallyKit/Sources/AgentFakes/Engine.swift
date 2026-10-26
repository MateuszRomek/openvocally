import Foundation

package enum FakeAgent {
  /// The persona comes from the binary's own path, `<root>/<scenario>/<provider>`, because the host
  /// owns argv and the environment. Any other path is the management tool.
  package static func main() async -> Int32 {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      return StdIO.fail("fake: cannot locate its own executable", exitCode: 2)
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let provider = Provider(rawValue: executable.lastPathComponent),
      let id = ScenarioID(rawValue: executable.deletingLastPathComponent().lastPathComponent)
    else {
      return Installer.manage(builtBinary: executable, arguments: arguments)
    }
    let scenario = Scenario.named(id)
    if let command = HealthCommand(provider, arguments) {
      return HealthAnswer.for(provider, scenario.health, command).write()
    }
    return await Session.run(
      provider, scenario, arguments: arguments, environment: ProcessInfo.processInfo.environment)
  }
}

extension Provider {
  /// Whether this provider's wire can raise `ask`. A test holds `Scenario.providers` to it.
  package func encodes(_ ask: Ask) -> Bool {
    switch self {
    case .claude: ClaudeWire.encodes(ask)
    case .codex: CodexWire.encodes(ask)
    }
  }
}

package enum HealthCommand: Equatable, Sendable {
  case version
  case loginStatus(text: Bool)

  package init?(_ provider: Provider, _ arguments: [String]) {
    switch (provider, arguments) {
    case (_, ["--version"]): self = .version
    case (.claude, ["auth", "status"]), (.claude, ["auth", "status", "--json"]):
      self = .loginStatus(text: false)
    case (.claude, ["auth", "status", "--text"]): self = .loginStatus(text: true)
    case (.codex, ["login", "status"]): self = .loginStatus(text: true)
    default: return nil
    }
  }
}

package struct HealthAnswer: Equatable, Sendable {
  package let stdout: String
  package let stderr: String
  package let exitCode: Int32

  /// Formats measured from claude 2.1.306 and codex-cli 0.164.0-alpha.11.1.
  package static func `for`(
    _ provider: Provider, _ profile: HealthProfile, _ command: HealthCommand
  ) -> HealthAnswer {
    let unreadable = HealthAnswer(stdout: "", stderr: "Error: could not read credentials\n", exitCode: 2)
    switch (provider, command, profile) {
    case (.claude, .version, _): return .init(stdout: "\(ClaudeWire.version(profile)) (Claude Code)\n")
    case (.codex, .version, _): return .init(stdout: "codex-cli \(CodexWire.version(profile))\n")
    case (_, .loginStatus, .needsAttention): return unreadable
    case (.claude, .loginStatus(text: false), .loggedOut):
      return .init(stdout: claudeStatus(loggedIn: false, method: "none"), exitCode: 1)
    case (.claude, .loginStatus(text: false), _):
      return .init(stdout: claudeStatus(loggedIn: true, method: "claude.ai"))
    case (.claude, .loginStatus(text: true), .loggedOut):
      return .init(stdout: "Not logged in. Run claude auth login to authenticate.\n", exitCode: 1)
    case (.claude, .loginStatus(text: true), _):
      return .init(
        stdout: """
          Login method: Claude Max account
          Organization: Fake Organization
          Email: fake@example.com
          Anthropic base URL: https://api.anthropic.com

          """)
    // Measured: codex writes its login status to stderr whether or not it is logged in.
    case (.codex, .loginStatus, .loggedOut): return .init(stdout: "", stderr: "Not logged in\n", exitCode: 1)
    case (.codex, .loginStatus, _): return .init(stdout: "", stderr: "Logged in using ChatGPT\n")
    }
  }

  private init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }

  private static func claudeStatus(loggedIn: Bool, method: String) -> String {
    "{\n  \"loggedIn\": \(loggedIn),\n  \"authMethod\": \"\(method)\",\n  \"apiProvider\": \"firstParty\"\n}\n"
  }

  func write() -> Int32 {
    StdIO.writeOut(stdout)
    StdIO.writeErr(stderr)
    return exitCode
  }
}

package enum Installer {
  /// The one layout rule: `<root>/<scenario>/<provider>`.
  package static func path(root: URL, _ provider: Provider, _ scenario: ScenarioID) -> URL {
    root.appending(path: scenario.rawValue).appending(path: provider.rawValue)
  }

  static let usage = """
    Usage: FakeAgentCLI install <root>   Copy the fake to <root>/<scenario>/<claude|codex>
           FakeAgentCLI --list           List every scenario and provider
           FakeAgentCLI --help

    """

  static func manage(builtBinary: URL, arguments: [String]) -> Int32 {
    switch arguments {
    case ["--help"]:
      StdIO.writeOut(usage)
      return 0
    case ["--list"]:
      StdIO.writeOut(installs.map { "\($0.id.rawValue)\t\($1.rawValue)\n" }.joined())
      return 0
    case _ where arguments.count == 2 && arguments[0] == "install":
      let root = arguments[1]
      do {
        let paths = try install(builtBinary: builtBinary, into: URL(filePath: root))
        StdIO.writeOut(paths.map { $0.path(percentEncoded: false) + "\n" }.joined())
        return 0
      } catch {
        return StdIO.fail("FakeAgentCLI: install failed: \(error.localizedDescription)", exitCode: 1)
      }
    default:
      StdIO.writeErr(usage)
      return 2
    }
  }

  private static var installs: [(Scenario, Provider)] {
    Scenario.all.flatMap { scenario in
      Provider.allCases.filter(scenario.providers.contains).map { (scenario, $0) }
    }
  }

  /// Copies rather than symlinks, so a host that resolves symlinks keeps the scenario directory.
  /// On APFS `copyItem` makes clones, so the copies cost almost nothing.
  static func install(builtBinary: URL, into root: URL) throws -> [URL] {
    let files = FileManager.default
    for scenario in Scenario.all {
      let directory = root.appending(path: scenario.id.rawValue)
      if files.fileExists(atPath: directory.path(percentEncoded: false)) {
        try files.removeItem(at: directory)
      }
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return try installs.map { scenario, provider in
      let target = path(root: root, provider, scenario.id)
      try files.copyItem(at: builtBinary, to: target)
      return target
    }
  }
}

/// One protocol: launch validation, frames, ids, and racing each wait against the host's interrupt.
protocol Wire: AnyObject {
  static func encodes(_ ask: Ask) -> Bool
  /// The exit code on stdin EOF after a failed turn.
  static var exitCodeAfterFailedTurn: Int32 { get }
  func start(resume: ResumeBehavior) async throws
  /// The next user message, or `nil` on stdin EOF.
  func nextUserTurn() async throws -> String?
  func openTurn(selfStarted: Bool) async throws
  func stream(_ chunks: [String]) async throws
  func ask(_ ask: Ask) async throws -> Reply
  func closeTurn(_ ending: TurnEnding) async throws
}

/// A deliberate end of the process that the host sees as an exit code and a stderr line.
struct SessionExit: Error {
  let code: Int32
  let stderr: String
}

enum Session {
  static func run(
    _ provider: Provider, _ scenario: Scenario, arguments: [String], environment: [String: String]
  ) async -> Int32 {
    guard let script = scenario.script else {
      return StdIO.fail(
        "fake \(provider.rawValue): the \(scenario.id.rawValue) scenario only answers health", exitCode: 2)
    }
    do {
      let wire: any Wire =
        switch provider {
        case .claude:
          try ClaudeWire(
            arguments: arguments, environment: environment, health: scenario.health, inbox: Inbox())
        case .codex: try CodexWire(arguments: arguments, health: scenario.health, inbox: Inbox())
        }
      try await wire.start(resume: scenario.resume)
      return try await SessionEngine(wire: wire).run(script)
    } catch let exit as SessionExit {
      return StdIO.fail(exit.stderr, exitCode: exit.code)
    } catch {
      return StdIO.fail("fake \(provider.rawValue): \(error.localizedDescription)", exitCode: 2)
    }
  }
}

struct SessionEngine {
  let wire: any Wire

  /// After the script, every further user turn gets "Okay.", so a host can send more turns than the
  /// script names. After a failed turn every further turn fails the same way, as a logged-out CLI's
  /// do, and stdin EOF exits with the code each real CLI uses.
  func run(_ script: [Beat]) async throws -> Int32 {
    let failedExit = type(of: wire).exitCodeAfterFailedTurn
    var stack = Array(script.reversed())
    var answers: [String] = []
    var failure: TurnFailure?
    while let beat = stack.popLast() {
      switch beat {
      case .awaitUserTurn:
        guard try await wire.nextUserTurn() != nil else { return failure == nil ? 0 : failedExit }
        try await wire.openTurn(selfStarted: false)
      case .selfStartTurn:
        try await wire.openTurn(selfStarted: true)
      case .stream(let text, let chunks):
        try await wire.stream(Chunker.split(text, chunks))
      case .echoAnswer(let prefix):
        try await wire.stream([prefix + answers.joined(separator: ", ")])
      case .ask(let ask, let approved, let declined):
        switch try await wire.ask(ask) {
        case .approved: stack += approved.reversed()
        case .answered(let values):
          answers = values
          stack += approved.reversed()
        case .declined: stack += declined.reversed()
        case .interrupted:
          try await wire.closeTurn(.interrupted)
          while let next = stack.last, next != .awaitUserTurn, next != .selfStartTurn { stack.removeLast() }
        }
      case .completeTurn:
        try await wire.closeTurn(.completed)
      case .failTurn(let turnFailure):
        failure = turnFailure
        try await wire.closeTurn(.failed(turnFailure))
      case .crash(let exitCode, let stderr):
        throw SessionExit(code: exitCode, stderr: stderr)
      }
    }
    while try await wire.nextUserTurn() != nil {
      try await wire.openTurn(selfStarted: false)
      if let failure {
        try await wire.closeTurn(.failed(failure))
        continue
      }
      try await wire.stream(["Okay."])
      try await wire.closeTurn(.completed)
    }
    return failure == nil ? 0 : failedExit
  }
}

enum Chunker {
  /// Fixed offsets, so deltas are identical on every run.
  static func split(_ text: String, _ chunks: Int) -> [String] {
    let characters = Array(text)
    let size = max(1, (characters.count + max(chunks, 1) - 1) / max(chunks, 1))
    return stride(from: 0, to: characters.count, by: size).map {
      String(characters[$0..<min($0 + size, characters.count)])
    }
  }
}

/// Deterministic ids: a counter, never `UUID()` or `Date()`.
struct Ids {
  private var counter = 0

  mutating func uuid() -> String {
    counter += 1
    let digits = String(counter)
    return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - digits.count) + digits
  }

  mutating func toolUse() -> String {
    counter += 1
    return "toolu_fake\(counter)"
  }

  mutating func next(_ kind: String) -> String {
    counter += 1
    return "fake-\(kind)-\(counter)"
  }
}

enum InboxEvent: Sendable {
  case frame(JSONValue)
  case malformed
  case hook(Data?)
  case eof
}

/// Every input the wire waits on, in arrival order: stdin lines and hook responses.
final class Inbox {
  let continuation: AsyncStream<InboxEvent>.Continuation
  private var iterator: AsyncStream<InboxEvent>.Iterator

  init() {
    let (stream, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
    self.continuation = continuation
    iterator = stream.makeAsyncIterator()
    Thread { Self.readStandardInput(into: continuation) }.start()
  }

  func next() async -> InboxEvent {
    await iterator.next(isolation: #isolation) ?? .eof
  }

  private static func readStandardInput(into continuation: AsyncStream<InboxEvent>.Continuation) {
    var buffer = Data()
    func yield(_ line: Data) {
      guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { return }
      continuation.yield((try? JSONValue(data: line)).map(InboxEvent.frame) ?? .malformed)
    }
    while true {
      let chunk = FileHandle.standardInput.availableData
      guard !chunk.isEmpty else {
        yield(buffer)
        continuation.yield(.eof)
        return
      }
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        yield(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
      }
    }
  }
}

enum StdIO {
  static func write(_ frame: JSONValue) {
    FileHandle.standardOutput.write(frame.data + Data([0x0A]))
  }

  static func writeOut(_ text: String) {
    if !text.isEmpty { FileHandle.standardOutput.write(Data(text.utf8)) }
  }

  static func writeErr(_ text: String) {
    if !text.isEmpty { FileHandle.standardError.write(Data(text.utf8)) }
  }

  static func fail(_ message: String, exitCode: Int32) -> Int32 {
    if !message.isEmpty { writeErr(message.hasSuffix("\n") ? message : message + "\n") }
    return exitCode
  }
}
