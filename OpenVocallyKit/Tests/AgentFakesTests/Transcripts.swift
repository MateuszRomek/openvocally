import AgentFakes
import AgentFakesTestSupport

/// How the host answers. `answerOnStdio` gives the hook no decision and answers the stdio control
/// request the fake falls back to.
enum HostChoice: String, Sendable, CaseIterable {
  case main, resume, plainOutput, approve, approveForSession, decline, interrupt, answerOnStdio
}

/// The reviewed oracle: literal frames written by hand, never recorded from the fake.
enum Transcripts {
  static func expected(for scenario: ScenarioID, provider: Provider, choice: HostChoice) -> HostTranscript? {
    switch provider {
    case .claude: Claude.expected(scenario, choice)
    case .codex: Codex.expected(scenario, choice)
    }
  }
}

private enum Claude {
  static let session = FakeHost.sessionID

  static func expected(_ scenario: ScenarioID, _ choice: HostChoice) -> HostTranscript? {
    switch scenario {
    case .streamedReply:
      let chunks = ["Here is a stre", "amed reply in ", "three parts."]
      switch choice {
      case .resume:
        let resumed = "33333333-3333-4333-8333-333333333333"
        return HostTranscript(
          launch: HostLaunch(resume: resumed),
          moves: turn("Hi", session: resumed) + says(chunks, session: resumed)
            + completes(chunks.joined(), session: resumed))
      case .plainOutput:
        return HostTranscript(
          launch: HostLaunch(partialMessages: false, sessionStateEvents: false),
          moves: [
            .send(user("Hi")),
            .expect(#"{"type":"system","subtype":"init","session_id":"\#(session)"}"#),
            .expect(assistant(chunks.joined())),
            .expect(
              #"{"type":"result","subtype":"success","is_error":false,"result":"\#(chunks.joined())"}"#),
            .closeInput, .exit(0),
          ])
      default:
        return HostTranscript(moves: turn("Hi") + says(chunks) + completes(chunks.joined()))
      }
    case .commandApproval:
      let request = #"""
        {"hook_event_name":"PermissionRequest","session_id":"\#(session)","permission_mode":"default",
         "tool_name":"Bash","tool_input":{"command":"swift build","description":"Run swift build in /tmp/fake-project"},
         "permission_suggestions":[\#(rule("Bash", "swift build"))]}
        """#
      return permission(
        before: says(["I'll build the project."]), request: request, tool: "Bash",
        input: #"{"command":"swift build","description":"Run swift build in /tmp/fake-project"}"#,
        suggestion: rule("Bash", "swift build"), approved: "Build succeeded.",
        declined: "Okay, I won't run it.",
        choice)
    case .fileApproval:
      let suggestion = #"{"type":"setMode","mode":"acceptEdits","destination":"session"}"#
      let request = #"""
        {"hook_event_name":"PermissionRequest","session_id":"\#(session)","tool_name":"Edit",
         "tool_input":{"file_path":"/tmp/fake-project/README.md","old_string":"# Fake",
                       "new_string":"# Fake\n\n## Usage","replace_all":false},
         "permission_suggestions":[\#(suggestion)]}
        """#
      return permission(
        before: [], request: request, tool: "Edit",
        input: #"""
          {"file_path":"/tmp/fake-project/README.md","old_string":"# Fake","new_string":"# Fake\n\n## Usage",
           "replace_all":false}
          """#,
        suggestion: suggestion, approved: "Updated README.md.",
        declined: "Left README.md as it was.", choice)
    case .chromeSiteApproval:
      let request = #"""
        {"hook_event_name":"PermissionRequest","session_id":"\#(session)",
         "tool_name":"mcp__claude-in-chrome__navigate","tool_input":{"url":"https://example.com/pricing"},
         "permission_suggestions":[\#(rule("ClaudeInChromeDomain", "example.com"))]}
        """#
      return permission(
        before: [], request: request, tool: "mcp__claude-in-chrome__navigate",
        input: #"{"url":"https://example.com/pricing"}"#,
        suggestion: rule("ClaudeInChromeDomain", "example.com"),
        approved: "The pricing page lists three plans.",
        declined: "I won't open that site.", choice)
    case .agentQuestion:
      let question = "Which branch should I merge into?"
      let input = #"""
        {"questions":[{"question":"\#(question)","header":"Target","multiSelect":false,
          "options":[{"label":"main","description":"main"},{"label":"release","description":"release"}]}]}
        """#
      let request =
        #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":\#(input)}"#
      let answer = #"{"behavior":"allow","updatedInput":{"answers":{"\#(question)":"release"}}}"#
      return ask(
        hookPath: "permission", request: request, hookEvent: "PermissionRequest",
        stdioRequest:
          #"{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":\#(input),"tool_use_id":"$tool"}"#,
        accept: (#"{"decision":\#(answer)}"#, answer), deny: #"{"decision":{"behavior":"deny"}}"#,
        approved: "Merging into release", declined: "Okay, I'll stop here.", choice,
        toolUse: ("AskUserQuestion", input, "The user denied this tool use."))
    case .mcpForm:
      let fields = #"""
        "mcp_server_name":"tickets","message":"Create a ticket","mode":"form",
        "requested_schema":{"type":"object","properties":{"title":{"type":"string","title":"Title"}},"required":["title"]}
        """#
      let accept = #"{"action":"accept","content":{"title":"Fix login"}}"#
      return ask(
        hookPath: "elicitation", request: #"{"hook_event_name":"Elicitation",\#(fields)}"#,
        hookEvent: "Elicitation", stdioRequest: #"{"subtype":"elicitation",\#(fields)}"#,
        accept: (#"{"action":"accept","content":{"title":"Fix login"}}"#, accept),
        deny: #"{"action":"decline"}"#, approved: "Created ticket: Fix login", declined: "No ticket created.",
        choice)
    case .mcpSignIn:
      let fields = #"""
        "mcp_server_name":"tickets","message":"Sign in to tickets","mode":"url",
        "url":"https://auth.example.com/authorize?client=fake","elicitation_id":"$*"
        """#
      return ask(
        hookPath: "elicitation", request: #"{"hook_event_name":"Elicitation",\#(fields)}"#,
        hookEvent: "Elicitation", stdioRequest: #"{"subtype":"elicitation",\#(fields)}"#,
        accept: (#"{"action":"accept"}"#, #"{"action":"accept"}"#), deny: #"{"action":"cancel"}"#,
        approved: "Signed in to tickets.", declined: "Sign-in cancelled.", choice)
    case .crashMidTurn:
      return HostTranscript(
        moves: turn("Go") + says(["Starting the ", "work and then"])
          + [.exit(1, stderr: "fake: simulated crash mid-turn")])
    case .loggedOut:
      let text = "Not logged in · Please run /login"
      return HostTranscript(
        moves: turn("Hi") + [
          .expect(
            #"""
            {"type":"assistant","error":"authentication_failed","is_api_error_message":true,"session_id":"\#(session)",
             "message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}
            """#),
          .expect(
            #"""
            {"type":"result","subtype":"success","is_error":true,"result":"\#(text)","terminal_reason":"api_error",
             "session_id":"\#(session)"}
            """#),
          .expect(state("idle")),
          .closeInput, .exit(1),
        ])
    case .belowMinimumVersion:
      return HostTranscript(
        moves: turn("Hi") + says(["Old version reply."]) + completes("Old version reply."))
    case .lostSession:
      guard choice == .resume else {
        return HostTranscript(
          moves: turn("Hi") + says(["Fresh session reply."]) + completes("Fresh session reply."))
      }
      let lost = "22222222-2222-4222-8222-222222222222"
      return HostTranscript(
        launch: HostLaunch(resume: lost),
        moves: [
          .expect(
            #"""
            {"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"\#(lost)",
             "errors":["No conversation found with session ID: \#(lost)"]}
            """#),
          .exit(1, stderr: "No conversation found with session ID: \(lost)"),
        ])
    case .selfStartedTurn:
      let later = ["Background check fi", "nished: all green."]
      return HostTranscript(
        moves: turn("Check") + says(["Started the background check."])
          + [.expect(result("Started the background check.")), .expect(state("idle"))]
          + [.expect(state("running"))] + says(later) + completes(later.joined()))
    case .computerUseApproval, .needsAttention:
      return nil
    }
  }

  static func user(_ text: String) -> String {
    #"{"type":"user","message":{"role":"user","content":"\#(text)"},"parent_tool_use_id":null,"session_id":""}"#
  }

  static func state(_ state: String, session: String = session) -> String {
    #"{"type":"system","subtype":"session_state_changed","state":"\#(state)","session_id":"\#(session)"}"#
  }

  /// The recorded order: the state frame comes before init.
  static func turn(_ text: String, session: String = session) -> [HostMove] {
    [
      .send(user(text)),
      .expect(state("running", session: session)),
      .expect(
        #"""
        {"type":"system","subtype":"init","session_id":"\#(session)","claude_code_version":"2.1.306",
         "permissionMode":"default"}
        """#),
    ]
  }

  static func assistant(_ text: String, session: String = session) -> String {
    #"""
    {"type":"assistant","session_id":"\#(session)","parent_tool_use_id":null,
     "message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}
    """#
  }

  static func says(_ chunks: [String], session: String = session) -> [HostMove] {
    chunks.map {
      .expect(
        #"""
        {"type":"stream_event","session_id":"\#(session)","parent_tool_use_id":null,
         "event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#($0)"}}}
        """#)
    } + [.expect(assistant(chunks.joined(), session: session))]
  }

  static func result(_ text: String, session: String = session) -> String {
    #"{"type":"result","subtype":"success","is_error":false,"result":"\#(text)","session_id":"\#(session)"}"#
  }

  static func completes(_ text: String, session: String = session) -> [HostMove] {
    [
      .expect(result(text, session: session)), .expect(state("idle", session: session)), .closeInput,
      .exit(0),
    ]
  }

  static func rule(_ tool: String, _ content: String) -> String {
    #"{"type":"addRules","rules":[{"toolName":"\#(tool)","ruleContent":"\#(content)"}],"behavior":"allow","destination":"session"}"#
  }

  static let interrupt =
    #"{"type":"control_request","request_id":"host-1","request":{"subtype":"interrupt"}}"#

  static let interrupted: [HostMove] = [
    .expect(
      #"{"type":"control_response","response":{"subtype":"success","request_id":"host-1","response":{"still_queued":[]}}}"#
    ),
    .expect(
      #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"\#(session)"}"#),
    .expect(state("idle")), .closeInput, .exit(0),
  ]

  static func permission(
    before: [HostMove], request: String, tool: String, input: String, suggestion: String, approved: String,
    declined: String, _ choice: HostChoice
  ) -> HostTranscript? {
    let allow = #"{"behavior":"allow"}"#
    let forSession = #"{"behavior":"allow","updatedPermissions":[\#(suggestion)]}"#
    let stdioRequest = #"""
      {"subtype":"can_use_tool","tool_name":"\#(tool)","input":\#(input),"tool_use_id":"$tool",
       "permission_suggestions":[\#(suggestion)]}
      """#
    if choice == .approveForSession {
      return HostTranscript(
        moves: turn("Go") + before + [
          .expect(toolUse(tool, input)), .expect(state("requires_action")),
          .hook(
            path: "permission", body: request,
            answer: hookAnswer("PermissionRequest", #"{"decision":\#(forSession)}"#)),
          .expect(state("running")), .expect(toolResult("fake tool output", isError: false)),
        ] + says([approved]) + completes(approved))
    }
    return ask(
      hookPath: "permission", request: request, hookEvent: "PermissionRequest", stdioRequest: stdioRequest,
      accept: (#"{"decision":\#(allow)}"#, allow), deny: #"{"decision":{"behavior":"deny","message":"No"}}"#,
      approved: approved, declined: declined, choice, before: before, toolUse: (tool, input, "No"))
  }

  static func toolUse(_ tool: String, _ input: String) -> String {
    #"""
    {"type":"assistant","session_id":"\#(session)","parent_tool_use_id":null,
     "message":{"role":"assistant","stop_reason":"tool_use",
                "content":[{"type":"tool_use","id":"$tool","name":"\#(tool)","input":\#(input)}]}}
    """#
  }

  static func toolResult(_ content: String, isError: Bool) -> String {
    #"""
    {"type":"user","session_id":"\#(session)","parent_tool_use_id":null,
     "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"$tool","content":"\#(content)",
                                           "is_error":\#(isError)}]}}
    """#
  }

  static func hookAnswer(_ event: String, _ fields: String) -> String {
    let inner = fields.dropFirst().dropLast()
    return #"{"hookSpecificOutput":{"hookEventName":"\#(event)",\#(inner)}}"#
  }

  /// `accept.hook` is the hook output's fields; `accept.stdio` is the control response payload. A
  /// permission ask names its tool use, which comes before the request and gets a result after it.
  static func ask(
    hookPath: String, request: String, hookEvent: String, stdioRequest: String,
    accept: (hook: String, stdio: String), deny: String, approved: String, declined: String,
    _ choice: HostChoice, before: [HostMove] = [],
    toolUse tool: (name: String, input: String, denial: String)? = nil
  ) -> HostTranscript? {
    let opening =
      turn("Go") + before + (tool.map { [.expect(toolUse($0.name, $0.input))] } ?? [])
      + [.expect(state("requires_action"))]
    func resumed(_ content: String, isError: Bool) -> [HostMove] {
      [.expect(state("running"))]
        + (tool == nil ? [] : [.expect(toolResult(isError ? tool?.denial ?? "" : content, isError: isError))])
    }
    switch choice {
    case .approve:
      return HostTranscript(
        moves: opening + [.hook(path: hookPath, body: request, answer: hookAnswer(hookEvent, accept.hook))]
          + resumed("fake tool output", isError: false) + says([approved]) + completes(approved))
    case .decline:
      return HostTranscript(
        moves: opening + [.hook(path: hookPath, body: request, answer: hookAnswer(hookEvent, deny))]
          + resumed("", isError: true) + says([declined]) + completes(declined))
    case .interrupt:
      return HostTranscript(
        moves: opening + [.hookLeftOpen(path: hookPath, body: request), .send(interrupt)] + interrupted)
    case .answerOnStdio:
      return HostTranscript(
        moves: opening + [
          .hook(path: hookPath, body: request, answer: "{}"),
          .expect(#"{"type":"control_request","request_id":"$request","request":\#(stdioRequest)}"#),
          .send(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"$request","response":\#(accept.stdio)}}"#
          ),
        ] + resumed("fake tool output", isError: false) + says([approved]) + completes(approved))
    case .main, .resume, .plainOutput, .approveForSession:
      return nil
    }
  }
}

private enum Codex {
  static func expected(_ scenario: ScenarioID, _ choice: HostChoice) -> HostTranscript? {
    switch scenario {
    case .streamedReply:
      let chunks = ["Here is a stre", "amed reply in ", "three parts."]
      guard choice == .resume else {
        return HostTranscript(moves: started() + turn("Hi") + says(chunks) + completes())
      }
      let resumed = "33333333-3333-4333-8333-333333333333"
      return HostTranscript(
        moves: handshake() + [
          .send(#"{"id":1,"method":"thread/resume","params":{"threadId":"\#(resumed)"}}"#),
          .expect(
            #"""
            {"id":1,"result":{"thread":{"id":"\#(resumed)","status":{"type":"idle"},"cliVersion":"0.164.0"},
             "model":"fake-model"}}
            """#),
        ] + turn("Hi", thread: resumed) + says(chunks, thread: resumed) + completes(thread: resumed))
    case .commandApproval:
      let item = #"""
        {"type":"commandExecution","id":"$tool","command":"swift build","cwd":"/tmp/fake-project",
         "source":"agent","status":"inProgress"}
        """#
      let request = #"""
        {"id":0,"method":"item/commandExecution/requestApproval",
         "params":{"kind":"command","threadId":"$thread","turnId":"$turn","itemId":"$tool",
                   "command":"swift build","cwd":"/tmp/fake-project","environmentId":null}}
        """#
      return approval(
        before: says(["I'll build the project."], item: "$intro"), item: item, request: request,
        approvedItem: #"{"type":"commandExecution","id":"$tool","status":"completed","exitCode":0}"#,
        declinedItem: #"{"type":"commandExecution","id":"$tool","status":"declined","exitCode":null}"#,
        accept: #"{"decision":"accept"}"#, forSession: #"{"decision":"acceptForSession"}"#,
        decline: #"{"decision":"decline"}"#, approved: "Build succeeded.", declined: "Okay, I won't run it.",
        choice)
    case .fileApproval:
      let item = #"""
        {"type":"fileChange","id":"$tool","status":"inProgress",
         "changes":[{"path":"/tmp/fake-project/README.md","kind":{"type":"update","move_path":null},
                     "diff":"@@ -1,1 +1,3 @@\n-# Fake\n+# Fake\n+\n+## Usage\n"}]}
        """#
      let request = #"""
        {"id":0,"method":"item/fileChange/requestApproval",
         "params":{"threadId":"$thread","turnId":"$turn","itemId":"$tool"}}
        """#
      return approval(
        before: [], item: item, request: request,
        approvedItem: #"{"type":"fileChange","id":"$tool","status":"completed"}"#,
        declinedItem: #"{"type":"fileChange","id":"$tool","status":"declined"}"#,
        accept: #"{"decision":"accept"}"#, forSession: #"{"decision":"acceptForSession"}"#,
        decline: #"{"decision":"decline"}"#, approved: "Updated README.md.",
        declined: "Left README.md as it was.",
        choice)
    case .computerUseApproval:
      let request = #"""
        {"id":0,"method":"mcpServer/elicitation/request",
         "params":{"threadId":"$thread","turnId":"$turn","serverName":"computer-use","mode":"form",
                   "message":"Allow Codex to use Finder?","requestedSchema":{"type":"object","properties":{}},
                   "_meta":{"codex_approval_kind":"mcp_tool_call","connector_name":"Computer Use",
                            "persist":["session","always"]}}}
        """#
      return approval(
        before: [], item: nil, request: request, approvedItem: "", declinedItem: "",
        accept: #"{"action":"accept","content":null,"_meta":null}"#,
        forSession: #"{"action":"accept","content":null,"_meta":{"persist":"session"}}"#,
        decline: #"{"action":"decline","content":null,"_meta":null}"#, approved: "Opened Finder.",
        declined: "I won't control Finder.", choice)
    case .mcpForm:
      let request = #"""
        {"id":0,"method":"mcpServer/elicitation/request",
         "params":{"threadId":"$thread","turnId":"$turn","serverName":"tickets","mode":"form","_meta":null,
                   "message":"Create a ticket",
                   "requestedSchema":{"type":"object","properties":{"title":{"type":"string","title":"Title"}},
                                      "required":["title"]}}}
        """#
      return approval(
        before: [], item: nil, request: request, approvedItem: "", declinedItem: "",
        accept: #"{"action":"accept","content":{"title":"Fix login"},"_meta":null}"#, forSession: nil,
        decline: #"{"action":"decline","content":null,"_meta":null}"#, approved: "Created ticket: Fix login",
        declined: "No ticket created.", choice)
    case .mcpSignIn:
      let request = #"""
        {"id":0,"method":"mcpServer/elicitation/request",
         "params":{"threadId":"$thread","turnId":"$turn","serverName":"tickets","mode":"url","_meta":null,
                   "message":"Sign in to tickets","url":"https://auth.example.com/authorize?client=fake",
                   "elicitationId":"$*"}}
        """#
      return approval(
        before: [], item: nil, request: request, approvedItem: "", declinedItem: "",
        accept: #"{"action":"accept","content":null,"_meta":null}"#, forSession: nil,
        decline: #"{"action":"cancel","content":null,"_meta":null}"#, approved: "Signed in to tickets.",
        declined: "Sign-in cancelled.", choice)
    case .crashMidTurn:
      return HostTranscript(
        moves: started() + turn("Go") + says(["Starting the ", "work and then"])
          + [.exit(1, stderr: "fake: simulated crash mid-turn")])
    case .loggedOut:
      let failure = #"""
        {"message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header",
         "codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":401}},"additionalDetails":null}
        """#
      return HostTranscript(
        moves: started() + turn("Hi") + [
          .expect(
            #"""
            {"method":"error","params":{"threadId":"$thread","turnId":"$turn","willRetry":true,
             "error":{"message":"Reconnecting... 1/5",
                      "codexErrorInfo":{"responseStreamDisconnected":{"httpStatusCode":401}}}}}
            """#),
          .expect(status(#"{"type":"systemError"}"#)),
          .expect(
            #"{"method":"error","params":{"threadId":"$thread","turnId":"$turn","willRetry":false,"error":\#(failure)}}"#
          ),
          .expect(
            #"""
            {"method":"turn/completed",
             "params":{"threadId":"$thread","turn":{"id":"$turn","status":"failed","error":\#(failure)}}}
            """#),
          .closeInput, .exit(0),
        ])
    case .belowMinimumVersion:
      return HostTranscript(
        moves: started(version: "0.150.0") + turn("Hi") + says(["Old version reply."]) + completes())
    case .lostSession:
      guard choice == .resume else {
        return HostTranscript(moves: started() + turn("Hi") + says(["Fresh session reply."]) + completes())
      }
      let lost = "22222222-2222-4222-8222-222222222222"
      return HostTranscript(
        moves: handshake() + [
          .send(#"{"id":1,"method":"thread/resume","params":{"threadId":"\#(lost)"}}"#),
          .expect(
            #"{"id":1,"error":{"code":-32600,"message":"no rollout found for thread id \#(lost)"}}"#),
        ] + startThread(id: 2) + turn("Hi", id: 3) + says(["Fresh session reply."]) + completes())
    case .chromeSiteApproval, .agentQuestion, .selfStartedTurn, .needsAttention:
      return nil
    }
  }

  static func handshake(version: String = "0.164.0") -> [HostMove] {
    [
      .send(
        #"{"id":0,"method":"initialize","params":{"clientInfo":{"name":"openvocally","title":null,"version":"1.0.5"},"capabilities":null}}"#
      ),
      .expect(
        #"""
        {"id":0,"result":{"userAgent":"openvocally/\#(version) (Mac OS 15.0.0; arm64) unknown (openvocally; 1.0.5)",
         "platformFamily":"unix","platformOs":"macos"}}
        """#),
      .expect(#"{"method":"remoteControl/status/changed","params":{"status":"disabled"}}"#),
      .send(#"{"method":"initialized"}"#),
    ]
  }

  static func startThread(id: Int = 1, version: String = "0.164.0") -> [HostMove] {
    [
      .send(#"{"id":\#(id),"method":"thread/start","params":{"cwd":null}}"#),
      .expect(
        #"""
        {"id":\#(id),"result":{"thread":{"id":"$thread","status":{"type":"idle"},"cliVersion":"\#(version)"},
         "model":"fake-model","approvalPolicy":"on-request"}}
        """#),
      .expect(#"{"method":"thread/started","params":{"thread":{"id":"$thread","status":{"type":"idle"}}}}"#),
    ]
  }

  static func started(version: String = "0.164.0") -> [HostMove] {
    handshake(version: version) + startThread(version: version)
  }

  static func status(_ status: String, thread: String = "$thread") -> String {
    #"{"method":"thread/status/changed","params":{"threadId":"\#(thread)","status":\#(status)}}"#
  }

  static func active(_ flags: String = "", thread: String = "$thread") -> String {
    status(#"{"type":"active","activeFlags":[\#(flags)]}"#, thread: thread)
  }

  static func item(_ phase: String, _ item: String, thread: String = "$thread") -> String {
    #"{"method":"item/\#(phase)","params":{"threadId":"\#(thread)","turnId":"$turn","item":\#(item)}}"#
  }

  /// The recorded order: the reply, the active status, `turn/started`, then the user message item.
  static func turn(_ text: String, id: Int = 2, thread: String = "$thread") -> [HostMove] {
    let message = #"""
      {"type":"userMessage","id":"$user","clientId":null,"content":[{"type":"text","text":"\#(text)","text_elements":[]}]}
      """#
    return [
      .send(
        #"{"id":\#(id),"method":"turn/start","params":{"threadId":"\#(thread)","input":[{"type":"text","text":"\#(text)","text_elements":[]}]}}"#
      ),
      .expect(
        #"""
        {"id":\#(id),"result":{"turn":{"id":"$turn","rootTurnId":"$turn","status":"inProgress","items":[],
         "error":null,"startedAt":null}}}
        """#),
      .expect(active(thread: thread)),
      .expect(
        #"{"method":"turn/started","params":{"threadId":"\#(thread)","turn":{"id":"$turn","status":"inProgress"}}}"#
      ),
      .expect(item("started", message, thread: thread)),
      .expect(item("completed", message, thread: thread)),
    ]
  }

  static func says(_ chunks: [String], item id: String = "$reply", thread: String = "$thread") -> [HostMove] {
    func message(_ text: String) -> String { #"{"type":"agentMessage","id":"\#(id)","text":"\#(text)"}"# }
    return [.expect(item("started", message(""), thread: thread))]
      + chunks.map {
        .expect(
          #"""
          {"method":"item/agentMessage/delta",
           "params":{"threadId":"\#(thread)","turnId":"$turn","itemId":"\#(id)","delta":"\#($0)"}}
          """#)
      } + [.expect(item("completed", message(chunks.joined()), thread: thread))]
  }

  static func completes(thread: String = "$thread") -> [HostMove] {
    [
      .expect(status(#"{"type":"idle"}"#, thread: thread)),
      .expect(
        #"""
        {"method":"turn/completed",
         "params":{"threadId":"\#(thread)","turn":{"id":"$turn","status":"completed","error":null}}}
        """#),
      .closeInput, .exit(0),
    ]
  }

  static let resolved =
    #"{"method":"serverRequest/resolved","params":{"threadId":"$thread","requestId":0}}"#

  /// `item` is the tool step that frames the request, if the ask has one. A `nil` `forSession` means
  /// the ask offers nothing to keep.
  static func approval(
    before: [HostMove], item tool: String?, request: String, approvedItem: String, declinedItem: String,
    accept: String, forSession: String?, decline: String, approved: String, declined: String,
    _ choice: HostChoice
  ) -> HostTranscript? {
    let opening =
      started() + turn("Go") + before + (tool.map { [.expect(item("started", $0))] } ?? [])
      + [.expect(active(#""waitingOnApproval""#)), .expect(request)]
    func answered(_ result: String, _ itemAfter: String, _ text: String) -> HostTranscript {
      HostTranscript(
        moves: opening + [
          .send(#"{"id":0,"result":\#(result)}"#), .expect(resolved), .expect(active()),
        ] + (tool == nil ? [] : [.expect(item("completed", itemAfter))]) + says([text]) + completes())
    }
    switch choice {
    case .approve: return answered(accept, approvedItem, approved)
    case .approveForSession: return forSession.map { answered($0, approvedItem, approved) }
    case .decline: return answered(decline, declinedItem, declined)
    case .interrupt:
      return HostTranscript(
        moves: opening + [
          .send(#"{"id":7,"method":"turn/interrupt","params":{"threadId":"$thread","turnId":"$turn"}}"#),
          .expect(#"{"id":7,"result":{}}"#), .expect(resolved), .expect(status(#"{"type":"idle"}"#)),
          .expect(
            #"""
            {"method":"turn/completed","params":{"threadId":"$thread","turn":{"id":"$turn","status":"interrupted"}}}
            """#),
          .closeInput, .exit(0),
        ])
    case .main, .resume, .plainOutput, .answerOnStdio:
      return nil
    }
  }
}
