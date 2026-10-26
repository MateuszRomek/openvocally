// Frames checked against codex-cli 0.164.0-alpha.11.1 and its `app-server generate-ts` bindings; the
// handshake, turn, interrupt, logged-out and lost-session frames were recorded from it.

import Foundation

/// `codex app-server`: newline-delimited JSON-RPC on stdio with no `jsonrpc` field.
final class CodexWire: Wire {
  private static let epochSeconds = 1_767_225_600
  private static let epochMs: JSONValue = .number(Double(epochSeconds) * 1000)
  private static let installationID = "00000000-0000-4000-8000-00000000c0de"

  private let inbox: Inbox
  private let cliVersion: String
  private var ids = Ids()
  private var nextRequestID = 0
  private var answeredInitialize = false
  private var initialized = false
  private var threadID = ""
  private var turnID = ""
  /// The id of the `turn/start` the next `openTurn` answers.
  private var pendingTurnStart: JSONValue?
  private var userText = ""

  /// The app-server is a server: a failed turn does not change how it exits.
  static let exitCodeAfterFailedTurn: Int32 = 0

  static func encodes(_ ask: Ask) -> Bool {
    switch ask {
    case .command, .fileChange, .computerUse, .mcpForm, .mcpSignIn, .mcpUnknownMode: true
    case .chromeSite, .question: false
    }
  }

  init(arguments: [String], health: HealthProfile, inbox: Inbox) throws {
    guard Self.subcommand(arguments) == "app-server" else {
      throw SessionExit(code: 2, stderr: "fake codex: the launch is missing the app-server subcommand")
    }
    self.inbox = inbox
    cliVersion = Self.version(health)
  }

  /// Global options that take a value, so the word after one is never the subcommand.
  private static let valueOptions: Set<String> = [
    "-c", "--config", "--enable", "--disable", "-p", "--profile",
  ]

  /// The first argument that is neither an option nor an option's value.
  private static func subcommand(_ arguments: [String]) -> String? {
    var rest = arguments[...]
    while let argument = rest.popFirst() {
      if valueOptions.contains(argument) {
        rest = rest.dropFirst()
      } else if !argument.hasPrefix("-") {
        return argument
      }
    }
    return nil
  }

  /// The measured version is a prerelease, so a host's version check must parse one.
  static func version(_ health: HealthProfile) -> String {
    health == .belowMinimumVersion ? "0.150.0" : "0.164.0-alpha.11.1"
  }

  func start(resume: ResumeBehavior) async throws {
    while threadID.isEmpty {
      guard let frame = try await nextFrame() else { throw SessionExit(code: 0, stderr: "") }
      try handleIdle(frame, resume: resume)
    }
  }

  func nextUserTurn() async throws -> String? {
    while true {
      guard let frame = try await nextFrame() else { return nil }
      if frame["method"] == "turn/start", let id = frame["id"] {
        guard frame["params"]?["threadId"]?.string == threadID else {
          respondError(id, code: -32600, "thread not found: \(frame["params"]?["threadId"]?.string ?? "")")
          continue
        }
        let input = frame["params"]?["input"]?.array ?? []
        // The bindings require `text_elements` on a text item, though codex 0.164 defaults it.
        guard input.allSatisfy({ $0["type"] != "text" || $0["text_elements"]?.array != nil }) else {
          respondError(id, code: -32602, "Invalid params: missing field `text_elements`")
          continue
        }
        pendingTurnStart = id
        userText = input.compactMap { $0["text"]?.string }.joined()
        return userText
      }
      try handleIdle(frame, resume: .resumes)
    }
  }

  func openTurn(selfStarted: Bool) async throws {
    turnID = ids.uuid()
    if let id = pendingTurnStart {
      respond(id, ["turn": .object(turn(status: "inProgress", replied: true))])
      pendingTurnStart = nil
    }
    notify("thread/status/changed", ["threadId": .string(threadID), "status": Self.active([])])
    notify("turn/started", ["threadId": .string(threadID), "turn": .object(turn(status: "inProgress"))])
    guard !selfStarted else { return }
    let item: JSONValue = [
      "type": "userMessage", "id": .string(ids.uuid()), "clientId": nil,
      "content": [["type": "text", "text": .string(userText), "text_elements": []]],
    ]
    itemStarted(item)
    itemCompleted(item)
  }

  func stream(_ chunks: [String]) async throws {
    let itemID = ids.uuid()
    func message(_ text: String) -> JSONValue {
      [
        "type": "agentMessage", "id": .string(itemID), "text": .string(text), "phase": nil,
        "memoryCitation": nil, "delivery": nil, "questions": nil,
      ]
    }
    itemStarted(message(""))
    for chunk in chunks {
      notify(
        "item/agentMessage/delta",
        [
          "threadId": .string(threadID), "turnId": .string(turnID), "itemId": .string(itemID),
          "delta": .string(chunk),
        ])
    }
    itemCompleted(message(chunks.joined()))
  }

  func closeTurn(_ ending: TurnEnding) async throws {
    switch ending {
    case .completed:
      notify("thread/status/changed", ["threadId": .string(threadID), "status": ["type": "idle"]])
      notify(
        "turn/completed",
        ["threadId": .string(threadID), "turn": .object(turn(status: "completed", ended: true))])
    case .interrupted:
      notify("thread/status/changed", ["threadId": .string(threadID), "status": ["type": "idle"]])
      notify(
        "turn/completed",
        ["threadId": .string(threadID), "turn": .object(turn(status: "interrupted", ended: true))])
    case .failed(.notLoggedIn):
      let details = "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
      error(
        message: "Reconnecting... 1/5", info: ["responseStreamDisconnected": ["httpStatusCode": 401]],
        details: .string(details), willRetry: true)
      notify("thread/status/changed", ["threadId": .string(threadID), "status": ["type": "systemError"]])
      let failure = error(
        message: details, info: ["httpConnectionFailed": ["httpStatusCode": 401]], details: nil,
        willRetry: false)
      var turn = turn(status: "failed", ended: true)
      turn["error"] = failure
      notify("turn/completed", ["threadId": .string(threadID), "turn": .object(turn)])
    }
  }

  func ask(_ ask: Ask) async throws -> Reply {
    var params: [String: JSONValue] = ["threadId": .string(threadID), "turnId": .string(turnID)]
    let method: String
    var item: [String: JSONValue]?
    switch ask {
    case .command(let command, let directory):
      method = "item/commandExecution/requestApproval"
      item = [
        "type": "commandExecution", "id": .string(ids.uuid()), "pluginId": nil, "scriptPath": nil,
        "command": .string(command), "cwd": .string(directory), "processId": nil, "source": "agent",
        "status": "inProgress", "commandActions": [], "aggregatedOutput": nil, "exitCode": nil,
        "durationMs": nil,
      ]
      params.merge([
        "kind": "command", "startedAtMs": Self.epochMs, "environmentId": nil, "command": .string(command),
        "cwd": .string(directory),
      ]) { _, new in new }
    case .fileChange(let path, let oldText, let newText):
      method = "item/fileChange/requestApproval"
      item = [
        "type": "fileChange", "id": .string(ids.uuid()),
        "changes": [
          [
            "path": .string(path), "kind": ["type": "update", "move_path": nil],
            "diff": .string(Self.diff(oldText, newText)),
          ]
        ],
        "status": "inProgress",
      ]
      params.merge(["startedAtMs": Self.epochMs, "reason": nil, "grantRoot": nil]) { _, new in new }
    case .computerUse(let app):
      method = "mcpServer/elicitation/request"
      params.merge([
        "serverName": "computer-use", "mode": "form", "message": .string("Allow Codex to use \(app)?"),
        "requestedSchema": ["type": "object", "properties": [:]],
        // The fake assumes this `_meta` shape; it is not recorded from a real Computer Use approval.
        "_meta": [
          "codex_approval_kind": "mcp_tool_call", "connector_name": "Computer Use",
          "persist": ["session", "always"],
        ],
      ]) { _, new in new }
    case .mcpForm(let server, let message, let fields):
      method = "mcpServer/elicitation/request"
      let properties = Dictionary(
        uniqueKeysWithValues: fields.map {
          ($0.name, JSONValue.object(["type": "string", "title": .string($0.title)]))
        })
      params.merge([
        "serverName": .string(server), "mode": "form", "message": .string(message), "_meta": nil,
        "requestedSchema": [
          "type": "object", "properties": .object(properties),
          "required": .array(fields.filter(\.required).map { .string($0.name) }),
        ],
      ]) { _, new in new }
    case .mcpSignIn(let server, let url):
      method = "mcpServer/elicitation/request"
      params.merge([
        "serverName": .string(server), "mode": "url", "message": .string("Sign in to \(server)"),
        "_meta": nil, "url": .string(url), "elicitationId": .string(ids.next("elicitation")),
      ]) { _, new in new }
    case .mcpUnknownMode(let server, let mode, let message):
      method = "mcpServer/elicitation/request"
      params.merge([
        "serverName": .string(server), "mode": .string(mode), "message": .string(message), "_meta": nil,
        "requestedSchema": ["type": "object", "properties": [:]],
      ]) { _, new in new }
    case .chromeSite, .question:
      throw SessionExit(code: 2, stderr: "fake codex: this ask is not a Codex scenario")
    }
    if let id = item?["id"] { params["itemId"] = id }
    if let item { itemStarted(.object(item)) }

    let requestID = JSONValue.number(Double(nextRequestID))
    nextRequestID += 1
    notify(
      "thread/status/changed", ["threadId": .string(threadID), "status": Self.active(["waitingOnApproval"])])
    StdIO.write(["id": requestID, "method": .string(method), "params": .object(params)])

    let reply: Reply
    while true {
      guard let frame = try await nextFrame() else { throw SessionExit(code: 0, stderr: "") }
      if frame["method"] == "turn/interrupt", let id = frame["id"] {
        if let refusal = interruptRefusal(frame["params"]) {
          respondError(id, code: -32600, refusal)
          continue
        }
        respond(id, [:])
        notify("serverRequest/resolved", ["threadId": .string(threadID), "requestId": requestID])
        return .interrupted
      }
      if frame["method"] == nil, frame["id"] == requestID {
        reply = try Self.decode(ask, frame)
        break
      }
      try handleIdle(frame, resume: .resumes)
    }
    notify("serverRequest/resolved", ["threadId": .string(threadID), "requestId": requestID])
    notify("thread/status/changed", ["threadId": .string(threadID), "status": Self.active([])])
    if var item {
      let approved = reply != .declined
      item["status"] = approved ? "completed" : "declined"
      if item["type"] == "commandExecution", approved {
        item["aggregatedOutput"] = "Build complete!\n"
        item["exitCode"] = 0
        item["durationMs"] = 0
      }
      itemCompleted(.object(item))
    }
    return reply
  }

  private static func decode(_ ask: Ask, _ frame: JSONValue) throws -> Reply {
    guard let result = frame["result"] else { return .declined }
    func bad() -> SessionExit { SessionExit(code: 2, stderr: "fake codex: bad reply \(frame.text)") }
    switch ask {
    case .command, .fileChange:
      switch result["decision"]?.string {
      case "accept", "acceptForSession": return .approved
      case "decline", "cancel": return .declined
      default: throw bad()
      }
    case .computerUse, .mcpForm, .mcpSignIn:
      switch result["action"]?.string {
      case "accept":
        if let persist = result["_meta"]?["persist"] {
          guard case .computerUse = ask, ["session", "always"].contains(persist.string) else { throw bad() }
        }
        guard case .mcpForm(_, _, let fields) = ask else { return .approved }
        return .answered(fields.compactMap { result["content"]?[$0.name]?.string })
      case "decline", "cancel": return .declined
      default: throw bad()
      }
    case .mcpUnknownMode:
      // The spec: a host declines an elicitation mode it cannot render.
      guard result["action"]?.string == "decline" else { throw bad() }
      return .declined
    case .chromeSite, .question:
      throw bad()
    }
  }

  /// The refusals codex 0.164 gives an interrupt that does not name the active turn.
  private func interruptRefusal(_ params: JSONValue?) -> String? {
    if let missing = ["threadId", "turnId"].first(where: { params?[$0]?.string == nil }) {
      return "Invalid request: missing field `\(missing)`"
    }
    let thread = params?["threadId"]?.string ?? ""
    let turn = params?["turnId"]?.string ?? ""
    if thread != threadID { return "thread not found: \(thread)" }
    if turn != turnID { return "expected active turn id \(turn) but found \(turnID)" }
    return nil
  }

  private static func diff(_ old: String, _ new: String) -> String {
    let removed = old.split(separator: "\n", omittingEmptySubsequences: false)
    let added = new.split(separator: "\n", omittingEmptySubsequences: false)
    return "@@ -1,\(removed.count) +1,\(added.count) @@\n" + removed.map { "-\($0)\n" }.joined()
      + added.map { "+\($0)\n" }.joined()
  }

  /// Answers the handshake and thread requests; notifications and stray responses are ignored.
  private func handleIdle(_ frame: JSONValue, resume: ResumeBehavior) throws {
    guard let method = frame["method"]?.string else { return }
    guard let id = frame["id"] else {
      if method == "initialized" { initialized = true }
      return
    }
    guard method == "initialize" || initialized else {
      respondError(id, code: -32002, "Not initialized")
      return
    }
    switch method {
    case "initialize":
      guard !answeredInitialize else {
        respondError(id, code: -32600, "Already initialized")
        return
      }
      answeredInitialize = true
      let client = frame["params"]?["clientInfo"]
      let name = client?["name"]?.string ?? ""
      let version = client?["version"]?.string ?? ""
      respond(
        id,
        [
          "userAgent": .string("\(name)/\(cliVersion) (Mac OS 15.0.0; arm64) unknown (\(name); \(version))"),
          "codexHome": "/tmp/fake-codex-home", "platformFamily": "unix", "platformOs": "macos",
        ])
      notify(
        "remoteControl/status/changed",
        [
          "status": "disabled", "serverName": "fake-host", "installationId": .string(Self.installationID),
          "environmentId": nil,
        ])
    case "thread/start", "thread/resume":
      let params = frame["params"]
      let sandbox: JSONValue
      do {
        sandbox = try Self.sandboxPolicy(method, params)
      } catch {
        respondError(id, code: -32602, error.message)
        return
      }
      guard method == "thread/resume" else {
        openThread(id, ids.uuid(), sandbox: sandbox, resumed: false)
        return
      }
      let requested = params?["threadId"]?.string ?? ""
      if resume == .sessionLost {
        respondError(id, code: -32600, "no rollout found for thread id \(requested)")
      } else {
        openThread(id, requested, sandbox: sandbox, resumed: true)
      }
    case "turn/interrupt":
      respondError(id, code: -32600, "no active turn to interrupt")
    default:
      respondError(id, code: -32601, "fake codex: unsupported method \(method)")
    }
  }

  private struct Refusal: Error {
    let message: String
  }

  /// The policy a thread response reports for the requested sandbox mode. Refuses a request that
  /// breaks the spec's contract: every approval goes to the user, decided per request.
  private static func sandboxPolicy(_ method: String, _ params: JSONValue?) throws(Refusal) -> JSONValue {
    for (key, expected) in [("approvalPolicy", "on-request"), ("approvalsReviewer", "user")] {
      let value = params?[key]
      if value?.string != expected {
        let got = value.map { ", got \($0.text)" } ?? ""
        throw Refusal(message: "Invalid params: \(method) needs \(key) \"\(expected)\"\(got)")
      }
    }
    switch params?["sandbox"] {
    case nil, .null?, .string("workspace-write")?:
      return [
        "type": "workspaceWrite", "writableRoots": [], "networkAccess": false, "excludeTmpdirEnvVar": false,
        "excludeSlashTmp": false,
      ]
    case .string("read-only")?: return ["type": "readOnly", "networkAccess": false]
    case .string("danger-full-access")?: return ["type": "dangerFullAccess"]
    case let other?: throw Refusal(message: "Invalid params: unknown sandbox mode \(other.text)")
    }
  }

  /// Carries every field the generated bindings mark required, with synthetic values and `null`
  /// wherever the type allows it.
  private func openThread(_ requestID: JSONValue, _ id: String, sandbox: JSONValue, resumed: Bool) {
    threadID = id
    let cwd = JSONValue.string(FileManager.default.currentDirectoryPath)
    let epoch = JSONValue.number(Double(Self.epochSeconds))
    let thread: JSONValue = [
      "id": .string(id), "sessionId": .string(id), "forkedFromId": nil, "parentThreadId": nil, "preview": "",
      "ephemeral": false, "section": nil, "sectionEnteredAt": nil, "projectId": nil,
      "historyMode": "paginated",
      "modelProvider": "openai", "model": "fake-model", "reasoningEffort": nil, "createdAt": epoch,
      "updatedAt": epoch, "recencyAt": epoch, "status": ["type": "idle"], "path": nil, "cwd": cwd,
      "cliVersion": .string(cliVersion), "originator": nil, "source": "vscode", "threadSource": nil,
      "agentNickname": nil, "agentRole": nil, "gitInfo": nil, "name": nil, "turns": [],
    ]
    var result: [String: JSONValue] = [
      "thread": thread, "model": "fake-model", "modelProvider": "openai", "serviceTier": nil,
      "disabledPluginIds": [], "cwd": cwd, "instructionSources": [], "approvalPolicy": "on-request",
      "approvalsReviewer": "user", "sandbox": sandbox, "reasoningEffort": nil,
    ]
    if resumed {
      result.merge(["collaborationMode": nil, "turnsBackwardsCursor": nil, "itemsBackwardsCursor": nil]) {
        _, new in new
      }
    }
    respond(requestID, .object(result))
    if !resumed { notify("thread/started", ["thread": thread]) }
  }

  /// The next stdin frame, or `nil` on EOF.
  private func nextFrame() async throws -> JSONValue? {
    while true {
      switch await inbox.next() {
      case .eof: return nil
      case .malformed: throw SessionExit(code: 1, stderr: "fake codex: a stdin line is not JSON")
      case .hook: continue
      case .frame(let frame): return frame
      }
    }
  }

  private static func active(_ flags: [JSONValue]) -> JSONValue {
    ["type": "active", "activeFlags": .array(flags)]
  }

  /// The `turn/start` reply has no start time yet; `turn/started` and `turn/completed` have one.
  private func turn(status: String, replied: Bool = false, ended: Bool = false) -> [String: JSONValue] {
    let epoch = JSONValue.number(Double(Self.epochSeconds))
    return [
      "id": .string(turnID), "rootTurnId": .string(turnID), "items": [], "itemsView": "notLoaded",
      "status": .string(status), "error": nil, "startedAt": replied ? nil : epoch,
      "completedAt": ended ? epoch : nil, "durationMs": ended ? 0 : nil,
    ]
  }

  private func itemStarted(_ item: JSONValue) {
    notify(
      "item/started",
      ["item": item, "threadId": .string(threadID), "turnId": .string(turnID), "startedAtMs": Self.epochMs])
  }

  private func itemCompleted(_ item: JSONValue) {
    notify(
      "item/completed",
      ["item": item, "threadId": .string(threadID), "turnId": .string(turnID), "completedAtMs": Self.epochMs])
  }

  @discardableResult
  private func error(message: String, info: JSONValue, details: JSONValue, willRetry: Bool) -> JSONValue {
    let error: JSONValue = [
      "message": .string(message), "codexErrorInfo": info, "additionalDetails": details, "misalignment": nil,
    ]
    notify(
      "error",
      [
        "error": error, "willRetry": .bool(willRetry), "threadId": .string(threadID),
        "turnId": .string(turnID),
      ])
    return error
  }

  private func notify(_ method: String, _ params: JSONValue) {
    StdIO.write(["method": .string(method), "params": params, "emittedAtMs": Self.epochMs])
  }

  private func respond(_ id: JSONValue, _ result: JSONValue) {
    StdIO.write(["id": id, "result": result])
  }

  private func respondError(_ id: JSONValue, code: Int, _ message: String) {
    StdIO.write(["id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
  }
}
