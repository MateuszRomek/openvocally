// Frames checked against claude 2.1.306 and the claude-agent-sdk 0.3.218 types; the logged-out and
// lost-session frames were recorded from claude 2.1.306.

import Foundation

struct ClaudeLaunch {
  enum Session {
    case new(id: String)
    case resume(id: String)
  }

  let session: Session
  let permissionMode: String
  let permissionHook: URL?
  let elicitationHook: URL?
  let emitsSessionState: Bool
  let includesPartialMessages: Bool

  private static let valued: Set<String> = [
    "--input-format", "--output-format", "--session-id", "--resume", "--settings", "--permission-mode",
    "--permission-prompt-tool",
  ]

  init(arguments: [String], environment: [String: String]) throws {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if let equals = argument.firstIndex(of: "="), Self.valued.contains(String(argument[..<equals])) {
        values[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
      } else if Self.valued.contains(argument), index + 1 < arguments.count {
        values[argument] = arguments[index + 1]
        index += 1
      } else {
        flags.insert(argument)
      }
      index += 1
    }
    func missing(_ what: String) -> SessionExit {
      SessionExit(code: 2, stderr: "fake claude: the launch is missing \(what)")
    }
    guard flags.contains("-p") || flags.contains("--print") else { throw missing("-p") }
    guard values["--output-format"] == "stream-json" else { throw missing("--output-format stream-json") }
    guard flags.contains("--verbose") else {
      throw SessionExit(
        code: 1, stderr: "Error: When using --print, --output-format=stream-json requires --verbose")
    }
    guard values["--input-format"] == "stream-json" else { throw missing("--input-format stream-json") }
    guard values["--permission-prompt-tool"] == "stdio" else {
      throw missing("--permission-prompt-tool stdio")
    }
    guard let permissionMode = values["--permission-mode"] else { throw missing("--permission-mode <mode>") }
    guard let settings = values["--settings"] else { throw missing("--settings <file>") }
    switch (values["--session-id"], values["--resume"]) {
    case (let id?, nil): session = .new(id: id)
    case (nil, let id?): session = .resume(id: id)
    default: throw missing("exactly one of --session-id <uuid> and --resume <id>")
    }
    let hooks: JSONValue
    do {
      let data =
        settings.hasPrefix("{") ? Data(settings.utf8) : try Data(contentsOf: URL(filePath: settings))
      hooks = try JSONValue(data: data)["hooks"] ?? [:]
    } catch {
      throw SessionExit(code: 1, stderr: "fake claude: cannot read --settings \(settings)")
    }
    func httpHook(_ event: String) -> URL? {
      let urls = (hooks[event]?.array ?? []).flatMap { $0["hooks"]?.array ?? [] }
        .filter { $0["type"] == "http" }.compactMap { $0["url"]?.string }
      return urls.first.flatMap(URL.init(string:))
    }
    self.permissionMode = permissionMode
    permissionHook = httpHook("PermissionRequest")
    elicitationHook = httpHook("Elicitation")
    emitsSessionState = environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"].map { !$0.isEmpty } ?? false
    includesPartialMessages = flags.contains("--include-partial-messages")
  }
}

final class ClaudeWire: Wire {
  private let launch: ClaudeLaunch
  private let inbox: Inbox
  private let sessionID: String
  private var ids = Ids()
  private var sentInit = false
  private var turnText = ""
  /// The message of the last `deny` decision, for the tool result.
  private var denial: String?

  init(arguments: [String], environment: [String: String], inbox: Inbox) throws {
    launch = try ClaudeLaunch(arguments: arguments, environment: environment)
    self.inbox = inbox
    switch launch.session {
    case .new(let id), .resume(let id): sessionID = id
    }
  }

  static let exitCodeAfterFailedTurn: Int32 = 1

  static func encodes(_ ask: Ask) -> Bool {
    if case .computerUse = ask { false } else { true }
  }

  func start(resume: ResumeBehavior) async throws {
    guard case .resume(let id) = launch.session, resume == .sessionLost else { return }
    let message = "No conversation found with session ID: \(id)"
    write([
      "type": "result", "subtype": "error_during_execution", "duration_ms": 0, "duration_api_ms": 0,
      "is_error": true, "num_turns": 0, "stop_reason": nil, "total_cost_usd": 0, "usage": Self.usage,
      "permission_denials": [], "errors": [.string(message)],
    ])
    throw SessionExit(code: 1, stderr: message)
  }

  func nextUserTurn() async throws -> String? {
    while true {
      switch await inbox.next() {
      case .eof: return nil
      case .malformed: throw SessionExit(code: 1, stderr: "fake claude: a stdin line is not JSON")
      case .hook: continue
      case .frame(let frame):
        if frame["type"] == "user" { return Self.text(of: frame["message"]?["content"]) }
        if frame["type"] == "control_request" { answerIdleControl(frame) }
      }
    }
  }

  func openTurn(selfStarted: Bool) async throws {
    turnText = ""
    state("running")
    guard !sentInit else { return }
    sentInit = true
    write([
      "type": "system", "subtype": "init", "cwd": .string(FileManager.default.currentDirectoryPath),
      "tools": ["AskUserQuestion", "Bash", "Edit", "Read", "Write"], "mcp_servers": [],
      "model": "claude-fake", "permissionMode": .string(launch.permissionMode), "apiKeySource": "none",
      "claude_code_version": "2.1.306", "output_style": "default",
    ])
  }

  func stream(_ chunks: [String]) async throws {
    if launch.includesPartialMessages {
      for chunk in chunks {
        write([
          "type": "stream_event", "parent_tool_use_id": nil,
          "event": [
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "text_delta", "text": .string(chunk)],
          ],
        ])
      }
    }
    turnText = chunks.joined()
    write(assistant([["type": "text", "text": .string(turnText)]], model: "claude-fake", stopReason: nil))
  }

  func closeTurn(_ ending: TurnEnding) async throws {
    switch ending {
    case .completed:
      write(result("success", isError: false, ["result": .string(turnText), "stop_reason": "end_turn"]))
    case .interrupted:
      write(result("error_during_execution", isError: true, ["stop_reason": nil]))
    case .failed(.notLoggedIn):
      let text = "Not logged in · Please run /login"
      var frame = assistant(
        [["type": "text", "text": .string(text)]], model: "<synthetic>", stopReason: "stop_sequence")
      frame["error"] = "authentication_failed"
      frame["is_api_error_message"] = true
      write(frame)
      write(
        result(
          "success", isError: true,
          ["result": .string(text), "stop_reason": "stop_sequence", "terminal_reason": "api_error"]))
    }
    state("idle")
  }

  private enum Route {
    case permission(tool: String, input: JSONValue, suggestions: [JSONValue])
    case elicitation(JSONValue, fields: [String]?)
  }

  func ask(_ ask: Ask) async throws -> Reply {
    let route = try route(ask)
    var toolUseID: String?
    if case .permission(let tool, let input, _) = route {
      let id = ids.toolUse()
      toolUseID = id
      write(
        assistant(
          [["type": "tool_use", "id": .string(id), "name": .string(tool), "input": input]],
          model: "claude-fake",
          stopReason: "tool_use"))
    }
    state("requires_action")
    denial = nil
    let reply = try await answer(route, toolUseID: toolUseID)
    guard reply != .interrupted else { return reply }
    state("running")
    if let toolUseID {
      let declined = reply == .declined
      write([
        "type": "user", "parent_tool_use_id": nil,
        "message": [
          "role": "user",
          "content": [
            [
              "type": "tool_result", "tool_use_id": .string(toolUseID),
              "content": .string(declined ? denial ?? "The user denied this tool use." : "fake tool output"),
              "is_error": .bool(declined),
            ]
          ],
        ],
      ])
    }
    return reply
  }

  private func route(_ ask: Ask) throws -> Route {
    switch ask {
    case .command(let command, let directory):
      return .permission(
        tool: "Bash",
        input: ["command": .string(command), "description": .string("Run \(command) in \(directory)")],
        suggestions: [Self.addRule(tool: "Bash", content: command)])
    case .fileChange(let path, let oldText, let newText):
      return .permission(
        tool: "Edit",
        input: [
          "file_path": .string(path), "old_string": .string(oldText), "new_string": .string(newText),
          "replace_all": false,
        ],
        suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
    case .chromeSite(let domain, let url):
      // The fake assumes this suggestion shape; it is not recorded from a real Chrome approval.
      return .permission(
        tool: "mcp__claude-in-chrome__navigate", input: ["url": .string(url)],
        suggestions: [Self.addRule(tool: "ClaudeInChromeDomain", content: domain)])
    case .question(let header, let question, let options):
      let choices = options.map { JSONValue.object(["label": .string($0), "description": .string($0)]) }
      return .permission(
        tool: "AskUserQuestion",
        input: [
          "questions": [
            [
              "question": .string(question), "header": .string(header), "options": .array(choices),
              "multiSelect": false,
            ]
          ]
        ],
        suggestions: [])
    case .mcpForm(let server, let message, let fields):
      let properties = Dictionary(
        uniqueKeysWithValues: fields.map {
          ($0.name, JSONValue.object(["type": "string", "title": .string($0.title)]))
        })
      return .elicitation(
        [
          "mcp_server_name": .string(server), "message": .string(message), "mode": "form",
          "requested_schema": [
            "type": "object", "properties": .object(properties),
            "required": .array(fields.filter(\.required).map { .string($0.name) }),
          ],
        ], fields: fields.map(\.name))
    case .mcpSignIn(let server, let url):
      return .elicitation(
        [
          "mcp_server_name": .string(server), "message": .string("Sign in to \(server)"), "mode": "url",
          "url": .string(url), "elicitation_id": .string(ids.next("elicitation")),
        ], fields: nil)
    case .computerUse:
      throw SessionExit(code: 2, stderr: "fake claude: computer use approvals are not a Claude scenario")
    }
  }

  private static func addRule(tool: String, content: String) -> JSONValue {
    [
      "type": "addRules", "rules": [["toolName": .string(tool), "ruleContent": .string(content)]],
      "behavior": "allow", "destination": "session",
    ]
  }

  /// Hook first; when the hook gives no decision, the stdio control request, as the real CLI falls back.
  private func answer(_ route: Route, toolUseID: String?) async throws -> Reply {
    let hookURL: URL?
    var hookBody: [String: JSONValue] = [
      "session_id": .string(sessionID), "transcript_path": .string("/tmp/fake-claude/\(sessionID).jsonl"),
      "cwd": .string(FileManager.default.currentDirectoryPath),
      "permission_mode": .string(launch.permissionMode),
    ]
    switch route {
    case .permission(let tool, let input, let suggestions):
      hookURL = launch.permissionHook
      hookBody["hook_event_name"] = "PermissionRequest"
      hookBody["tool_name"] = .string(tool)
      hookBody["tool_input"] = input
      if !suggestions.isEmpty { hookBody["permission_suggestions"] = .array(suggestions) }
    case .elicitation(let fields, _):
      hookURL = launch.elicitationHook
      hookBody["hook_event_name"] = "Elicitation"
      hookBody.merge(fields.object ?? [:]) { _, new in new }
    }
    var hook: Task<Void, Never>?
    defer { hook?.cancel() }
    if let hookURL {
      hook = post(JSONValue.object(hookBody), to: hookURL)
      while true {
        switch await inbox.next() {
        case .hook(let data):
          if let data, let reply = try decode(route, hookOutput: try? JSONValue(data: data)) { return reply }
        case .frame(let frame):
          if let interrupt = interruptID(frame) { return interrupted(interrupt, cancelling: nil) }
          continue
        case .eof: throw SessionExit(code: 0, stderr: "")
        case .malformed: continue
        }
        break
      }
    }
    let requestID = ids.next("req")
    var request: [String: JSONValue]
    switch route {
    case .permission(let tool, let input, let suggestions):
      request = [
        "subtype": "can_use_tool", "tool_name": .string(tool), "input": input,
        "tool_use_id": .string(toolUseID ?? ""),
      ]
      if !suggestions.isEmpty { request["permission_suggestions"] = .array(suggestions) }
    case .elicitation(let fields, _):
      request = (fields.object ?? [:]).merging(["subtype": "elicitation"]) { _, new in new }
    }
    write(["type": "control_request", "request_id": .string(requestID), "request": .object(request)])
    while true {
      switch await inbox.next() {
      case .frame(let frame):
        if let interrupt = interruptID(frame) { return interrupted(interrupt, cancelling: requestID) }
        guard frame["type"] == "control_response", frame["response"]?["request_id"]?.string == requestID
        else { continue }
        guard frame["response"]?["subtype"] == "success" else { return .declined }
        return try decode(route, decision: frame["response"]?["response"]) ?? .declined
      case .eof: throw SessionExit(code: 0, stderr: "")
      case .hook, .malformed: continue
      }
    }
  }

  private func decode(_ route: Route, hookOutput: JSONValue?) throws -> Reply? {
    let output = hookOutput?["hookSpecificOutput"]
    switch route {
    case .permission: return try decode(route, decision: output?["decision"])
    case .elicitation: return try decode(route, decision: output)
    }
  }

  /// A PermissionRequest decision (hook or `can_use_tool` response) or an elicitation result.
  private func decode(_ route: Route, decision: JSONValue?) throws -> Reply? {
    guard let decision else { return nil }
    switch route {
    case .permission(_, let input, let suggestions):
      switch decision["behavior"]?.string {
      case "deny":
        denial = decision["message"]?.string
        return .declined
      case "allow":
        if let granted = decision["updatedPermissions"]?.array,
          !granted.allSatisfy(suggestions.contains)
        {
          throw SessionExit(code: 2, stderr: "fake claude: updatedPermissions is not an offered suggestion")
        }
        guard let answers = decision["updatedInput"]?["answers"] else { return .approved }
        let questions = input["questions"]?.array ?? []
        return .answered(questions.compactMap { answers[$0["question"]?.string ?? ""]?.string })
      default: return nil
      }
    case .elicitation(_, let fields):
      switch decision["action"]?.string {
      case "accept":
        guard let fields else { return .approved }
        return .answered(fields.compactMap { decision["content"]?[$0]?.string })
      case "decline", "cancel": return .declined
      default: return nil
      }
    }
  }

  private func post(_ body: JSONValue, to url: URL) -> Task<Void, Never> {
    var request = URLRequest(url: url, timeoutInterval: 600)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body.data
    let continuation = inbox.continuation
    return Task {
      let response = try? await URLSession.shared.data(for: request)
      guard !Task.isCancelled else { return }
      let succeeded = (response?.1 as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      continuation.yield(.hook(succeeded ? response?.0 : nil))
    }
  }

  private func interruptID(_ frame: JSONValue) -> String? {
    guard frame["type"] == "control_request", frame["request"]?["subtype"] == "interrupt" else { return nil }
    return frame["request_id"]?.string ?? ""
  }

  private func interrupted(_ interruptID: String, cancelling requestID: String?) -> Reply {
    if let requestID { write(["type": "control_cancel_request", "request_id": .string(requestID)]) }
    respond(to: interruptID, ["still_queued": []])
    return .interrupted
  }

  private func answerIdleControl(_ frame: JSONValue) {
    let requestID = frame["request_id"]?.string ?? ""
    switch frame["request"]?["subtype"]?.string {
    case "interrupt": respond(to: requestID, ["still_queued": []])
    case "initialize": respond(to: requestID, ["commands": [], "output_style": "default"])
    case let subtype:
      write([
        "type": "control_response",
        "response": [
          "subtype": "error", "request_id": .string(requestID),
          "error": .string("fake claude: unsupported control request \(subtype ?? "")"),
        ],
      ])
    }
  }

  private func respond(to requestID: String, _ response: JSONValue) {
    write([
      "type": "control_response",
      "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
    ])
  }

  private static let usage: JSONValue = [
    "input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
  ]

  private static func text(of content: JSONValue?) -> String {
    if let text = content?.string { return text }
    return (content?.array ?? []).compactMap { $0["text"]?.string }.joined()
  }

  private func state(_ state: String) {
    guard launch.emitsSessionState else { return }
    write(["type": "system", "subtype": "session_state_changed", "state": .string(state)])
  }

  private func assistant(_ content: [JSONValue], model: String, stopReason: JSONValue) -> [String: JSONValue]
  {
    [
      "type": "assistant", "parent_tool_use_id": nil,
      "message": [
        "id": .string(ids.next("msg")), "type": "message", "role": "assistant", "model": .string(model),
        "content": .array(content), "stop_reason": stopReason,
        "usage": Self.usage,
      ],
    ]
  }

  private func result(_ subtype: String, isError: Bool, _ fields: [String: JSONValue]) -> [String: JSONValue]
  {
    [
      "type": "result", "subtype": .string(subtype), "is_error": .bool(isError), "duration_ms": 0,
      "duration_api_ms": 0, "num_turns": 1, "total_cost_usd": 0, "usage": Self.usage,
      "permission_denials": [],
    ].merging(fields) { _, new in new }
  }

  /// Every message frame carries the session id and a fresh uuid, as the real CLI's do; control frames
  /// carry neither.
  private func write(_ frame: [String: JSONValue]) {
    var frame = frame
    if frame["type"]?.string?.hasPrefix("control_") != true {
      frame["session_id"] = .string(sessionID)
      frame["uuid"] = .string(ids.uuid())
    }
    StdIO.write(.object(frame))
  }
}
