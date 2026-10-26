import AgentFakes
import Foundation
import Network
import Synchronization
import Testing

/// One host move. Frames are JSON text: `"$name"` captures a value on first sight and must equal it
/// after, `"$*"` matches anything, objects match as subsets and arrays match element by element.
package enum HostMove: Sendable {
  /// Write this frame to stdin, with captures substituted.
  case send(String)
  /// The next stdout frame must match.
  case expect(String)
  /// The next hook POST must go to `path` and match `body`; it is answered with `answer`.
  case hook(path: String, body: String, answer: String)
  /// The next hook POST must match and is never answered.
  case hookLeftOpen(path: String, body: String)
  case closeInput
  /// Stdout ends with no further frame and the process exits with `code`; stderr contains `stderr`.
  case exit(Int32, stderr: String = "")
}

package struct HostLaunch: Sendable {
  package var resume: String?
  package var partialMessages = true
  package var sessionStateEvents = true

  package init(resume: String? = nil, partialMessages: Bool = true, sessionStateEvents: Bool = true) {
    self.resume = resume
    self.partialMessages = partialMessages
    self.sessionStateEvents = sessionStateEvents
  }
}

package struct HostTranscript: Sendable {
  package var launch: HostLaunch
  package var moves: [HostMove]

  package init(launch: HostLaunch = HostLaunch(), moves: [HostMove]) {
    self.launch = launch
    self.moves = moves
  }
}

/// Launches a fake with the provider's real launch contract and plays a transcript against it. The
/// transcript is the host's script and the oracle at once: every frame the fake writes must be
/// matched, in order.
package enum FakeHost {
  package static let sessionID = "11111111-1111-4111-8111-111111111111"

  package static func play(
    _ transcript: HostTranscript, as provider: Provider, _ scenario: ScenarioID, fakes: FakeAgents,
    timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let hooks = try await HookServer.start()
    let directory = FileManager.default.temporaryDirectory.appending(path: "fake-host-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let process = Process()
    process.executableURL = fakes.path(provider, scenario)
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    switch provider {
    case .claude:
      let settings = directory.appending(path: "settings.json")
      try hooks.settings.data.write(to: settings)
      process.arguments = claudeArguments(transcript.launch, settings: settings)
      environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = transcript.launch.sessionStateEvents ? "1" : nil
    case .codex:
      process.arguments = ["app-server"]
    }
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
    process.terminationHandler = { exited.yield($0.terminationStatus) }
    var lines = Self.lines(of: output.fileHandleForReading).makeAsyncIterator()
    var stderr = Self.all(of: errors.fileHandleForReading).makeAsyncIterator()
    var exitCodes = exits.makeAsyncIterator()
    var requests = hooks.requests.makeAsyncIterator()
    try process.run()

    let timedOut = Atomic(false)
    let watchdog = Task {
      do { try await Task.sleep(for: timeout) } catch { return }
      timedOut.store(true, ordering: .relaxed)
      process.terminate()
      hooks.stop()
    }
    defer {
      watchdog.cancel()
      if process.isRunning { process.terminate() }
      hooks.stop()
    }

    func closed() -> String {
      timedOut.load(ordering: .relaxed)
        ? "the fake timed out after \(timeout) and was terminated"
        : "the fake closed stdout"
    }

    var captures: [String: JSONValue] = [:]
    var openRequests: [HookRequest] = []
    for (index, move) in transcript.moves.enumerated() {
      let failure: String?
      switch move {
      case .send(let frame):
        let data = FramePattern.render(try JSONValue(data: Data(frame.utf8)), captures: captures).data
        do {
          try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
          failure = nil
        } catch {
          failure = "could not write \(frame): \(closed())"
        }
      case .expect(let pattern):
        guard let line = await lines.next(isolation: #isolation) else {
          failure = "expected \(pattern)\n  but \(closed())"
          break
        }
        failure = FramePattern.check(pattern, line, captures: &captures)
      case .hook(let path, let body, let answer):
        guard let request = await requests.next(isolation: #isolation) else {
          failure = "expected a hook POST to /\(path)\n  but \(closed())"
          break
        }
        failure = request.check(path: path, body: body, captures: &captures)
        request.respond(FramePattern.render(try JSONValue(data: Data(answer.utf8)), captures: captures).data)
      case .hookLeftOpen(let path, let body):
        guard let request = await requests.next(isolation: #isolation) else {
          failure = "expected a hook POST to /\(path)\n  but \(closed())"
          break
        }
        failure = request.check(path: path, body: body, captures: &captures)
        openRequests.append(request)
      case .closeInput:
        try? input.fileHandleForWriting.close()
        failure = nil
      case .exit(let code, let expectedError):
        if let line = await lines.next(isolation: #isolation) {
          failure =
            "expected the fake to exit, got an unexpected frame\n  frame: \(String(decoding: line, as: UTF8.self))"
          break
        }
        let status = await exitCodes.next(isolation: #isolation)
        let errorText = String(decoding: await stderr.next(isolation: #isolation) ?? Data(), as: UTF8.self)
        if status != code {
          failure =
            "expected exit code \(code), got \(status.map(String.init) ?? "none"); stderr: \(errorText)"
        } else if !expectedError.isEmpty, !errorText.contains(expectedError) {
          failure = "expected stderr to contain \(expectedError), got \(errorText)"
        } else {
          failure = nil
        }
      }
      if let failure {
        Issue.record(
          "move \(index + 1) of \(transcript.moves.count): \(failure)", sourceLocation: sourceLocation)
        break
      }
    }
    for request in openRequests { request.drop() }
  }

  private static func claudeArguments(_ launch: HostLaunch, settings: URL) -> [String] {
    var arguments = ["-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json"]
    if launch.partialMessages { arguments.append("--include-partial-messages") }
    arguments += launch.resume.map { ["--resume", $0] } ?? ["--session-id", sessionID]
    arguments += [
      "--settings", settings.path(percentEncoded: false), "--permission-mode", "default",
      "--permission-prompt-tool", "stdio",
    ]
    return arguments
  }

  private static func lines(of handle: FileHandle) -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    Thread {
      var buffer = Data()
      while true {
        let chunk = handle.availableData
        guard !chunk.isEmpty else { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
          continuation.yield(Data(buffer[buffer.startIndex..<newline]))
          buffer.removeSubrange(buffer.startIndex...newline)
        }
      }
      if !buffer.isEmpty { continuation.yield(buffer) }
      continuation.finish()
    }.start()
    return stream
  }

  private static func all(of handle: FileHandle) -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    Thread {
      continuation.yield(handle.readDataToEndOfFile())
      continuation.finish()
    }.start()
    return stream
  }
}

package enum FramePattern {
  /// `nil` when `line` matches `pattern`; otherwise a message naming the key path, the pattern and the frame.
  package static func check(_ pattern: String, _ line: Data, captures: inout [String: JSONValue]) -> String? {
    let frame = String(decoding: line, as: UTF8.self)
    guard let expected = try? JSONValue(data: Data(pattern.utf8)) else {
      return "pattern is not JSON: \(pattern)"
    }
    guard let actual = try? JSONValue(data: line) else { return "frame is not JSON: \(frame)" }
    guard let mismatch = match(expected, actual, at: "$", captures: &captures) else { return nil }
    return "\(mismatch)\n  pattern: \(expected.text)\n  frame:   \(frame)"
  }

  package static func match(
    _ expected: JSONValue, _ actual: JSONValue?, at path: String, captures: inout [String: JSONValue]
  ) -> String? {
    if case .string(let name) = expected, name.hasPrefix("$") {
      guard let actual else { return "\(path): expected a value for \(name), got nothing" }
      if name == "$*" { return nil }
      if let captured = captures[name] {
        return captured == actual ? nil : "\(path): expected \(name) = \(captured.text), got \(actual.text)"
      }
      captures[name] = actual
      return nil
    }
    switch (expected, actual) {
    case (.object(let fields), .object(let values)?):
      for key in fields.keys.sorted() {
        if let mismatch = match(fields[key] ?? .null, values[key], at: "\(path).\(key)", captures: &captures)
        {
          return mismatch
        }
      }
      return nil
    case (.array(let items), .array(let values)?) where items.count == values.count:
      for (index, item) in items.enumerated() {
        if let mismatch = match(item, values[index], at: "\(path)[\(index)]", captures: &captures) {
          return mismatch
        }
      }
      return nil
    default:
      return expected == actual ? nil : "\(path): expected \(expected.text), got \(actual?.text ?? "nothing")"
    }
  }

  package static func render(_ value: JSONValue, captures: [String: JSONValue]) -> JSONValue {
    switch value {
    case .string(let name) where name.hasPrefix("$"): captures[name] ?? value
    case .object(let fields): .object(fields.mapValues { render($0, captures: captures) })
    case .array(let items): .array(items.map { render($0, captures: captures) })
    default: value
    }
  }
}

/// A loopback HTTP/1.1 listener that hands each POST to the transcript.
package final class HookServer: Sendable {
  let requests: AsyncStream<HookRequest>
  private let continuation: AsyncStream<HookRequest>.Continuation
  private let listener: NWListener
  private let port: UInt16

  private init(
    listener: NWListener, port: UInt16, requests: AsyncStream<HookRequest>,
    continuation: AsyncStream<HookRequest>.Continuation
  ) {
    self.listener = listener
    self.port = port
    self.requests = requests
    self.continuation = continuation
  }

  static func start() async throws -> HookServer {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let (requests, continuation) = AsyncStream.makeStream(of: HookRequest.self)
    let queue = DispatchQueue(label: "HookServer")
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      HookRequest.read(connection, Data()) { continuation.yield($0) }
    }
    let port = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
      let resumed = Atomic(false)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if !resumed.exchange(true, ordering: .relaxed) {
            ready.resume(returning: listener.port?.rawValue ?? 0)
          }
        case .failed(let error):
          if !resumed.exchange(true, ordering: .relaxed) { ready.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
    return HookServer(listener: listener, port: port, requests: requests, continuation: continuation)
  }

  /// The settings file content a host writes for Claude: both hooks point here.
  var settings: JSONValue {
    func hook(_ path: String) -> JSONValue {
      [
        [
          "matcher": "*",
          "hooks": [["type": "http", "url": .string("http://127.0.0.1:\(port)/\(path)"), "timeout": 600]],
        ]
      ]
    }
    return ["hooks": ["PermissionRequest": hook("permission"), "Elicitation": hook("elicitation")]]
  }

  func stop() {
    listener.cancel()
    continuation.finish()
  }
}

struct HookRequest: Sendable {
  let path: String
  let body: Data
  let connection: NWConnection

  func check(path expectedPath: String, body pattern: String, captures: inout [String: JSONValue]) -> String?
  {
    guard path == "/\(expectedPath)" else { return "expected a hook POST to /\(expectedPath), got \(path)" }
    return FramePattern.check(pattern, body, captures: &captures).map { "hook \(path): \($0)" }
  }

  func respond(_ body: Data) {
    let head =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }

  func drop() { connection.cancel() }

  static func read(
    _ connection: NWConnection, _ buffer: Data, then deliver: @escaping @Sendable (HookRequest) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
      let buffer = buffer + (data ?? Data())
      if let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let length =
          lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
          }.first ?? 0
        let body = buffer[headerEnd.upperBound...]
        if body.count >= length {
          let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
          deliver(HookRequest(path: path, body: Data(body.prefix(length)), connection: connection))
          return
        }
      }
      if isComplete || error != nil {
        connection.cancel()
        return
      }
      read(connection, buffer, then: deliver)
    }
  }
}
