import AgentFakes
import AgentFakesTestSupport

/// How the host answers. The `OnStdio` choices give the hook no decision and answer the stdio control
/// request the fake falls back to. `idleControl` sends control requests before the first turn.
enum HostChoice: String, Sendable, CaseIterable {
  case main, resume, plainOutput, idleControl, approve, approveForSession, decline, interrupt
  case answerOnStdio, declineOnStdio, interruptOnStdio
}

/// Claude host moves outside the choice matrix: input while an ask waits, and host mistakes the fake
/// must make loud.
enum ClaudeEdge: String, Sendable, CaseIterable {
  case inputWhileAsking, denyAndInterrupt, wrongHookEvent, changedInput, stdioDenyWithoutMessage
}

/// Codex host moves outside the choice matrix: requests that break the protocol or the spec contract,
/// which the fake must refuse.
enum CodexEdge: String, Sendable, CaseIterable {
  case secondInitialize, threadWithoutApprovalPolicy, wrongApprovalsReviewer, textWithoutElements
  case acceptUnknownMode

  var scenario: ScenarioID { self == .acceptUnknownMode ? .mcpUnknownMode : .streamedReply }
}

/// The reviewed oracle: literal frames written by hand, never recorded from the fake.
enum Transcripts {
  static func expected(for scenario: ScenarioID, provider: Provider, choice: HostChoice) -> HostTranscript? {
    switch provider {
    case .claude: Claude.expected(scenario, choice)
    case .codex: Codex.expected(scenario, choice)
    }
  }

  /// Every edge case plays the command-approval scenario.
  static func expected(for edge: ClaudeEdge) -> HostTranscript { Claude.expected(edge) }

  static func expected(for edge: CodexEdge) -> HostTranscript { Codex.expected(edge) }
}

private enum Claude {
  static let session = FakeHost.sessionID

  /// Copied from the init frame claude 2.1.306 wrote.
  static let capabilities = #"""
    ["interrupt_receipt_v1","interrupt_cancel_queued_v1","interrupt_send_now_v1","msg_lifecycle_v1",
     "request_marker_lists_v1","sdk_mcp_tools_list_changed","sdk_mcp_manifests","mcp_read_resource_v1",
     "mcp_tool_ui_meta_v1","ui_surface_v1","mcp_call_result_not_for_model_v1"]
    """#

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
          launch: HostLaunch(partialMessages: false, sessionStateEvents: "0"),
          moves: [
            .send(user("Hi")),
            .expect(#"{"type":"system","subtype":"init","session_id":"\#(session)"}"#),
            .expect(assistant(chunks.joined(), id: "$*")),
            .expect(result(chunks.joined())),
            .closeInput, .exit(0),
          ])
      case .idleControl:
        let modes = "default, acceptEdits, auto, bypassPermissions, dontAsk, plan"
        return HostTranscript(
          launch: HostLaunch(sessionStateEvents: "TRUE"),
          moves: [
            .send(control("host-1", #"{"subtype":"initialize"}"#)),
            .expect(success("host-1", #"{"commands":[],"output_style":"default"}"#)),
            .send(control("host-2", #"{"subtype":"interrupt"}"#)),
            .expect(success("host-2", #"{"still_queued":[]}"#)),
            .send(control("host-3", #"{"subtype":"rewind_files","user_message_id":"x"}"#)),
            .expect(failure("host-3", "fake claude: unsupported control request rewind_files")),
            .send(control("host-4", #"{"subtype":"set_permission_mode","mode":"yolo"}"#)),
            .expect(failure("host-4", "fake claude: invalid permission mode yolo; valid modes are \(modes)")),
            .send(control("host-5", #"{"subtype":"set_permission_mode","mode":"acceptEdits"}"#)),
            .expect(success("host-5")),
          ] + turn("Hi", mode: "acceptEdits") + says(chunks) + completes(chunks.joined()))
      default:
        return HostTranscript(moves: turn("Hi") + says(chunks) + completes(chunks.joined()))
      }
    case .commandApproval:
      return permission(
        before: says(["I'll build the project."]), request: Bash.request, tool: "Bash", input: Bash.input,
        suggestion: Bash.suggestion, approved: "Build succeeded.", declined: "Okay, I won't run it.", choice)
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
      let questions = #"""
        [{"question":"\#(question)","header":"Target","multiSelect":false,
          "options":[{"label":"main","description":"main"},{"label":"release","description":"release"}]}]
        """#
      let input = #"{"questions":\#(questions)}"#
      let request =
        #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":\#(input)}"#
      let answer =
        #"{"behavior":"allow","updatedInput":{"questions":\#(questions),"answers":{"\#(question)":"release"}}}"#
      return ask(
        hookPath: "permission", request: request, hookEvent: "PermissionRequest",
        stdioRequest:
          #"{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":\#(input),"tool_use_id":"$tool"}"#,
        accept: (#"{"decision":\#(answer)}"#, answer),
        deny: (#"{"decision":{"behavior":"deny"}}"#, #"{"behavior":"deny","message":"No"}"#),
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
        accept: (accept, accept), deny: (#"{"action":"decline"}"#, #"{"action":"decline"}"#),
        approved: "Created ticket: Fix login", declined: "No ticket created.", choice)
    case .mcpSignIn:
      let fields = #"""
        "mcp_server_name":"tickets","message":"Sign in to tickets","mode":"url",
        "url":"https://auth.example.com/authorize?client=fake","elicitation_id":"$*"
        """#
      return ask(
        hookPath: "elicitation", request: #"{"hook_event_name":"Elicitation",\#(fields)}"#,
        hookEvent: "Elicitation", stdioRequest: #"{"subtype":"elicitation",\#(fields)}"#,
        accept: (#"{"action":"accept"}"#, #"{"action":"accept"}"#),
        deny: (#"{"action":"cancel"}"#, #"{"action":"cancel"}"#),
        approved: "Signed in to tickets.", declined: "Sign-in cancelled.", choice)
    case .crashMidTurn:
      return HostTranscript(
        moves: turn("Go") + says(["Starting the ", "work and then"])
          + [.exit(1, stderr: "fake: simulated crash mid-turn")])
    case .loggedOut:
      let text = "Not logged in · Please run /login"
      let fails: [HostMove] = [
        .expect(
          #"""
          {"type":"assistant","error":"authentication_failed","is_api_error_message":true,"session_id":"\#(session)",
           "message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}
          """#),
        .expect(
          #"""
          {"type":"result","subtype":"success","is_error":true,"result":"\#(text)","terminal_reason":"api_error",
           "session_id":"\#(session)","modelUsage":{},"permission_denials":[]}
          """#),
        .expect(state("idle")),
      ]
      // A logged-out CLI fails every turn, not only the first.
      return HostTranscript(
        moves: turn("Hi") + fails + [.send(user("Again")), .expect(state("running"))] + fails + [
          .closeInput, .exit(1),
        ])
    case .belowMinimumVersion:
      return HostTranscript(
        moves: turn("Hi", version: "2.1.200") + says(["Old version reply."]) + completes("Old version reply.")
      )
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
             "errors":["No conversation found with session ID: \#(lost)"],"modelUsage":{},"permission_denials":[]}
            """#),
          .exit(1, stderr: "No conversation found with session ID: \(lost)"),
        ])
    case .selfStartedTurn:
      let later = ["Background check fi", "nished: all green."]
      return HostTranscript(
        moves: turn("Check") + says(["Started the background check."])
          + [.expect(result("Started the background check.")), .expect(state("idle"))]
          + [.expect(state("running"))] + says(later) + completes(later.joined()))
    case .computerUseApproval, .mcpUnknownMode, .needsAttention:
      return nil
    }
  }

  static func expected(_ edge: ClaudeEdge) -> HostTranscript {
    let opening = turn("Go") + says(["I'll build the project."]) + [.expect(toolUse("Bash", Bash.input))]
    let onStdio: [HostMove] = [
      .hook(path: "permission", body: Bash.request, answer: "{}"), .expect(state("requires_action")),
      .expect(controlRequest(Bash.stdio)),
    ]
    switch edge {
    case .inputWhileAsking:
      // The user message waits for the next turn; the control request is answered at once.
      return HostTranscript(
        moves: opening + onStdio + [
          .send(user("Then test it")),
          .send(control("host-2", #"{"subtype":"set_model","model":"claude-other"}"#)),
          .expect(success("host-2")),
          .send(controlResponse(#"{"behavior":"allow"}"#)),
          .expect(state("running")), .expect(toolResult("fake tool output", isError: false)),
        ] + says(["Build succeeded."]) + [
          .expect(result("Build succeeded.")), .expect(state("idle")), .expect(state("running")),
        ] + says(["Okay."]) + completes("Okay."))
    case .denyAndInterrupt:
      return HostTranscript(
        moves: opening + [
          .hook(
            path: "permission", body: Bash.request,
            answer: hookAnswer(
              "PermissionRequest", #"{"decision":{"behavior":"deny","message":"Stop","interrupt":true}}"#))
        ] + interruptedEnd(denials: denials("Bash", Bash.input)))
    case .wrongHookEvent:
      return HostTranscript(
        moves: opening + [
          .hook(
            path: "permission", body: Bash.request,
            answer: hookAnswer("Elicitation", #"{"decision":{"behavior":"allow"}}"#)),
          .exit(2, stderr: "bad hook output"),
        ])
    case .changedInput:
      let changed =
        #"{"behavior":"allow","updatedInput":{"command":"swift build -c release","description":"x"}}"#
      return HostTranscript(
        moves: opening + [
          .hook(
            path: "permission", body: Bash.request,
            answer: hookAnswer("PermissionRequest", #"{"decision":\#(changed)}"#)),
          .exit(2, stderr: "updatedInput"),
        ])
    case .stdioDenyWithoutMessage:
      return HostTranscript(
        moves: opening + onStdio + [
          .send(controlResponse(#"{"behavior":"deny"}"#)), .exit(2, stderr: "deny without a message"),
        ])
    }
  }

  enum Bash {
    static let input = #"{"command":"swift build","description":"Run swift build in /tmp/fake-project"}"#
    static let suggestion = rule("Bash", "swift build")
    static let request = #"""
      {"hook_event_name":"PermissionRequest","session_id":"\#(session)","permission_mode":"default",
       "tool_name":"Bash","tool_input":\#(input),"permission_suggestions":[\#(suggestion)]}
      """#
    static let stdio = #"""
      {"subtype":"can_use_tool","tool_name":"Bash","input":\#(input),"tool_use_id":"$tool",
       "permission_suggestions":[\#(suggestion)]}
      """#
  }

  static func user(_ text: String) -> String {
    #"{"type":"user","message":{"role":"user","content":"\#(text)"},"parent_tool_use_id":null,"session_id":""}"#
  }

  static func control(_ id: String, _ request: String) -> String {
    #"{"type":"control_request","request_id":"\#(id)","request":\#(request)}"#
  }

  static func success(_ id: String, _ response: String? = nil) -> String {
    let payload = response.map { #","response":\#($0)"# } ?? ""
    return #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)"\#(payload)}}"#
  }

  static func failure(_ id: String, _ error: String) -> String {
    #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)","error":"\#(error)"}}"#
  }

  static func controlRequest(_ request: String) -> String {
    #"{"type":"control_request","request_id":"$request","request":\#(request)}"#
  }

  static func controlResponse(_ response: String) -> String {
    #"{"type":"control_response","response":{"subtype":"success","request_id":"$request","response":\#(response)}}"#
  }

  static func state(_ state: String, session: String = session) -> String {
    #"{"type":"system","subtype":"session_state_changed","state":"\#(state)","session_id":"\#(session)","uuid":"$*"}"#
  }

  /// The recorded order: the state frame comes before init.
  static func turn(
    _ text: String, session: String = session, mode: String = "default", version: String = "2.1.306"
  ) -> [HostMove] {
    [
      .send(user(text)),
      .expect(state("running", session: session)),
      .expect(
        #"""
        {"type":"system","subtype":"init","session_id":"\#(session)","uuid":"$*","claude_code_version":"\#(version)",
         "permissionMode":"\#(mode)","slash_commands":[],"skills":[],"plugins":[],"capabilities":\#(capabilities)}
        """#),
    ]
  }

  static func assistant(_ text: String, id: String, session: String = session) -> String {
    #"""
    {"type":"assistant","session_id":"\#(session)","uuid":"$*","parent_tool_use_id":null,
     "message":{"id":"\#(id)","role":"assistant","stop_reason":null,"content":[{"type":"text","text":"\#(text)"}]}}
    """#
  }

  /// The stream events wrap one text block. The assistant message comes at the block's end, before
  /// `content_block_stop`, and carries the id `message_start` announced.
  static func says(_ chunks: [String], session: String = session) -> [HostMove] {
    let text = chunks.joined()
    let id = "$message \(text)"
    func event(_ event: String) -> HostMove {
      .expect(
        #"{"type":"stream_event","session_id":"\#(session)","uuid":"$*","parent_tool_use_id":null,"event":\#(event)}"#
      )
    }
    return [
      event(
        #"""
        {"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","model":"claude-fake",
         "content":[],"stop_reason":null,"usage":{"input_tokens":0,"output_tokens":0}}}
        """#),
      event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
    ]
      + chunks.map {
        event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#($0)"}}"#)
      } + [
        .expect(assistant(text, id: id, session: session)),
        event(#"{"type":"content_block_stop","index":0}"#),
        event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}"#),
        event(#"{"type":"message_stop"}"#),
      ]
  }

  static func result(_ text: String, session: String = session, denials: String = "[]") -> String {
    #"""
    {"type":"result","subtype":"success","is_error":false,"result":"\#(text)","session_id":"\#(session)",
     "uuid":"$*","modelUsage":{},"permission_denials":\#(denials)}
    """#
  }

  static func completes(_ text: String, session: String = session, denials: String = "[]") -> [HostMove] {
    [
      .expect(result(text, session: session, denials: denials)), .expect(state("idle", session: session)),
      .closeInput, .exit(0),
    ]
  }

  static func denials(_ tool: String, _ input: String) -> String {
    #"[{"tool_name":"\#(tool)","tool_use_id":"$tool","tool_input":\#(input)}]"#
  }

  static func rule(_ tool: String, _ content: String) -> String {
    #"{"type":"addRules","rules":[{"toolName":"\#(tool)","ruleContent":"\#(content)"}],"behavior":"allow","destination":"session"}"#
  }

  static let interrupt = control("host-1", #"{"subtype":"interrupt"}"#)

  /// The turn's end after an interrupt, from the host or from a `deny` that asks for one.
  static func interruptedEnd(denials: String = "[]") -> [HostMove] {
    [
      .expect(
        #"""
        {"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"\#(session)",
         "errors":[],"modelUsage":{},"permission_denials":\#(denials)}
        """#),
      .expect(state("idle")), .closeInput, .exit(0),
    ]
  }

  static let interrupted: [HostMove] =
    [.expect(success("host-1", #"{"still_queued":[]}"#))] + interruptedEnd()

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
          .expect(toolUse(tool, input)),
          .hook(
            path: "permission", body: request,
            answer: hookAnswer("PermissionRequest", #"{"decision":\#(forSession)}"#)),
          .expect(toolResult("fake tool output", isError: false)),
        ] + says([approved]) + completes(approved))
    }
    let deny = #"{"behavior":"deny","message":"No"}"#
    return ask(
      hookPath: "permission", request: request, hookEvent: "PermissionRequest", stdioRequest: stdioRequest,
      accept: (#"{"decision":\#(allow)}"#, allow), deny: (#"{"decision":\#(deny)}"#, deny),
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

  /// `accept` and `deny` hold the hook output's fields and the control response payload. A permission
  /// ask names its tool use, which comes before the request and gets a result after it; `denial` is
  /// that result's text when the hook denies. Claude emits no waiting state while the hook is pending,
  /// only when it falls back to the stdio request.
  static func ask(
    hookPath: String, request: String, hookEvent: String, stdioRequest: String,
    accept: (hook: String, stdio: String), deny: (hook: String, stdio: String), approved: String,
    declined: String, _ choice: HostChoice, before: [HostMove] = [],
    toolUse tool: (name: String, input: String, denial: String)? = nil
  ) -> HostTranscript? {
    let opening = turn("Go") + before + (tool.map { [.expect(toolUse($0.name, $0.input))] } ?? [])
    let denied = tool.map { denials($0.name, $0.input) } ?? "[]"
    let fallback: [HostMove] = [
      .hook(path: hookPath, body: request, answer: "{}"), .expect(state("requires_action")),
      .expect(controlRequest(stdioRequest)),
    ]
    func answered(_ response: String) -> [HostMove] {
      fallback + [.send(controlResponse(response)), .expect(state("running"))]
    }
    func ends(_ text: String, toolOutput: String, isError: Bool) -> [HostMove] {
      (tool == nil ? [] : [.expect(toolResult(toolOutput, isError: isError))]) + says([text])
        + completes(text, denials: isError ? denied : "[]")
    }
    switch choice {
    case .approve:
      return HostTranscript(
        moves: opening + [.hook(path: hookPath, body: request, answer: hookAnswer(hookEvent, accept.hook))]
          + ends(approved, toolOutput: "fake tool output", isError: false))
    case .decline:
      return HostTranscript(
        moves: opening + [.hook(path: hookPath, body: request, answer: hookAnswer(hookEvent, deny.hook))]
          + ends(declined, toolOutput: tool?.denial ?? "", isError: true))
    case .interrupt:
      return HostTranscript(
        moves: opening + [.hookLeftOpen(path: hookPath, body: request), .send(interrupt)] + interrupted)
    case .answerOnStdio:
      return HostTranscript(
        moves: opening + answered(accept.stdio)
          + ends(approved, toolOutput: "fake tool output", isError: false))
    case .declineOnStdio:
      return HostTranscript(
        moves: opening + answered(deny.stdio) + ends(declined, toolOutput: "No", isError: true))
    case .interruptOnStdio:
      return HostTranscript(
        moves: opening + fallback + [
          .send(interrupt), .expect(#"{"type":"control_cancel_request","request_id":"$request"}"#),
        ] + interrupted)
    case .main, .resume, .plainOutput, .idleControl, .approveForSession:
      return nil
    }
  }
}

private enum Codex {
  static let version = "0.164.0-alpha.11.1"
  static let chunks = ["Here is a stre", "amed reply in ", "three parts."]
  /// The spec's contract: every approval goes to the user, decided per request.
  static let approvals = #""approvalPolicy":"on-request","approvalsReviewer":"user""#
  static let workspaceWrite = #"""
    {"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,
     "excludeSlashTmp":false}
    """#

  static func expected(_ scenario: ScenarioID, _ choice: HostChoice) -> HostTranscript? {
    switch scenario {
    case .streamedReply:
      guard choice == .resume else {
        return HostTranscript(moves: started() + turn("Hi") + says(chunks) + completes())
      }
      let resumed = "33333333-3333-4333-8333-333333333333"
      return HostTranscript(
        moves: handshake() + [
          .send(
            #"""
            {"id":1,"method":"thread/resume",
             "params":{"threadId":"\#(resumed)",\#(approvals),"sandbox":"read-only"}}
            """#),
          .expect(
            threadResult(
              id: 1, thread: resumed, sandbox: #"{"type":"readOnly","networkAccess":false}"#, resumed: true)),
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
    case .mcpUnknownMode:
      // The host cannot render this mode, so declining is its only correct answer.
      guard choice != .approve else { return nil }
      return approval(
        before: [], item: nil, request: unknownModeRequest, approvedItem: "", declinedItem: "", accept: "",
        forSession: nil, decline: #"{"action":"decline","content":null,"_meta":null}"#, approved: "",
        declined: "Skipped the form.", choice)
    case .crashMidTurn:
      return HostTranscript(
        moves: started() + turn("Go") + says(["Starting the ", "work and then"])
          + [.exit(1, stderr: "fake: simulated crash mid-turn")])
    case .loggedOut:
      // A logged-out CLI fails every turn, not only the first.
      return HostTranscript(
        moves: started() + turn("Hi") + fails() + turn("Again", id: 3, turnID: "$turn2")
          + fails(turn: "$turn2")
          + [.closeInput, .exit(0)])
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
          .send(#"{"id":1,"method":"thread/resume","params":{"threadId":"\#(lost)",\#(approvals)}}"#),
          .expect(
            #"{"id":1,"error":{"code":-32600,"message":"no rollout found for thread id \#(lost)"}}"#),
        ] + startThread(id: 2) + turn("Hi", id: 3) + says(["Fresh session reply."]) + completes())
    case .chromeSiteApproval, .agentQuestion, .selfStartedTurn, .needsAttention:
      return nil
    }
  }

  static func expected(_ edge: CodexEdge) -> HostTranscript {
    func refused(_ id: Int, code: Int, _ message: String) -> HostMove {
      .expect(#"{"id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#)
    }
    let afterRefusal = startThread(id: 2) + turn("Hi", id: 3) + says(chunks) + completes()
    switch edge {
    case .secondInitialize:
      return HostTranscript(
        moves: handshake() + [
          .send(
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"openvocally","version":"1.0.5"}}}"#
          ),
          refused(1, code: -32600, "Already initialized"),
        ] + afterRefusal)
    case .threadWithoutApprovalPolicy:
      return HostTranscript(
        moves: handshake() + [
          .send(#"{"id":1,"method":"thread/start","params":{"cwd":null,"approvalsReviewer":"user"}}"#),
          refused(1, code: -32602, #"Invalid params: thread/start needs approvalPolicy \"on-request\""#),
        ] + afterRefusal)
    case .wrongApprovalsReviewer:
      let resume = #"""
        {"id":1,"method":"thread/resume",
         "params":{"threadId":"33333333-3333-4333-8333-333333333333","approvalPolicy":"on-request",
                   "approvalsReviewer":"auto_review"}}
        """#
      return HostTranscript(
        moves: handshake() + [
          .send(resume),
          refused(
            1, code: -32602,
            #"Invalid params: thread/resume needs approvalsReviewer \"user\", got \"auto_review\""#),
        ] + afterRefusal)
    case .textWithoutElements:
      return HostTranscript(
        moves: started() + [
          .send(
            #"{"id":2,"method":"turn/start","params":{"threadId":"$thread","input":[{"type":"text","text":"Hi"}]}}"#
          ),
          refused(2, code: -32602, "Invalid params: missing field `text_elements`"),
        ] + turn("Hi", id: 3) + says(chunks) + completes())
    case .acceptUnknownMode:
      return HostTranscript(
        moves: started() + turn("Go") + [
          .expect(active(#""waitingOnApproval""#)), .expect(unknownModeRequest),
          .send(#"{"id":0,"result":{"action":"accept","content":{},"_meta":null}}"#),
          .exit(2, stderr: "bad reply"),
        ])
    }
  }

  static let unknownModeRequest = #"""
    {"id":0,"method":"mcpServer/elicitation/request",
     "params":{"threadId":"$thread","turnId":"$turn","serverName":"tickets","mode":"openai/form","_meta":null,
               "message":"Fill in the ticket form","requestedSchema":{"type":"object","properties":{}}}}
    """#

  static func handshake(version: String = version) -> [HostMove] {
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

  /// Every field `Thread` in the generated bindings marks required, with the fake's synthetic values.
  static func thread(_ id: String, version: String = version) -> String {
    #"""
    {"id":"\#(id)","sessionId":"\#(id)","forkedFromId":null,"parentThreadId":null,"preview":"","ephemeral":false,
     "section":null,"sectionEnteredAt":null,"projectId":null,"historyMode":"paginated","modelProvider":"openai",
     "model":"fake-model","reasoningEffort":null,"createdAt":1767225600,"updatedAt":1767225600,
     "recencyAt":1767225600,"status":{"type":"idle"},"path":null,"cwd":"$*","cliVersion":"\#(version)",
     "originator":null,"source":"vscode","threadSource":null,"agentNickname":null,"agentRole":null,
     "gitInfo":null,"name":null,"turns":[]}
    """#
  }

  /// Every field `ThreadStartResponse` (or `ThreadResumeResponse`) marks required.
  static func threadResult(
    id: Int, thread: String, version: String = version, sandbox: String = workspaceWrite,
    resumed: Bool = false
  ) -> String {
    let resumeFields = #","collaborationMode":null,"turnsBackwardsCursor":null,"itemsBackwardsCursor":null"#
    return #"""
      {"id":\#(id),"result":{"thread":\#(Self.thread(thread, version: version)),"model":"fake-model",
       "modelProvider":"openai","serviceTier":null,"disabledPluginIds":[],"cwd":"$*","instructionSources":[],
       \#(approvals),"sandbox":\#(sandbox),"reasoningEffort":null\#(resumed ? resumeFields : "")}}
      """#
  }

  static func startThread(id: Int = 1, version: String = version) -> [HostMove] {
    [
      .send(#"{"id":\#(id),"method":"thread/start","params":{"cwd":null,\#(approvals)}}"#),
      .expect(threadResult(id: id, thread: "$thread", version: version)),
      .expect(#"{"method":"thread/started","params":{"thread":\#(thread("$thread", version: version))}}"#),
    ]
  }

  static func started(version: String = version) -> [HostMove] {
    handshake(version: version) + startThread(version: version)
  }

  static func status(_ status: String, thread: String = "$thread") -> String {
    #"{"method":"thread/status/changed","params":{"threadId":"\#(thread)","status":\#(status)}}"#
  }

  static func active(_ flags: String = "", thread: String = "$thread") -> String {
    status(#"{"type":"active","activeFlags":[\#(flags)]}"#, thread: thread)
  }

  static func item(_ phase: String, _ item: String, thread: String = "$thread", turn: String = "$turn")
    -> String
  {
    #"{"method":"item/\#(phase)","params":{"threadId":"\#(thread)","turnId":"\#(turn)","item":\#(item)}}"#
  }

  /// The recorded order: the reply, the active status, `turn/started`, then the user message item.
  static func turn(_ text: String, id: Int = 2, thread: String = "$thread", turnID: String = "$turn")
    -> [HostMove]
  {
    let message = #"""
      {"type":"userMessage","id":"$*","clientId":null,"content":[{"type":"text","text":"\#(text)","text_elements":[]}]}
      """#
    return [
      .send(
        #"{"id":\#(id),"method":"turn/start","params":{"threadId":"\#(thread)","input":[{"type":"text","text":"\#(text)","text_elements":[]}]}}"#
      ),
      .expect(
        #"""
        {"id":\#(id),"result":{"turn":{"id":"\#(turnID)","rootTurnId":"\#(turnID)","status":"inProgress","items":[],
         "error":null,"startedAt":null}}}
        """#),
      .expect(active(thread: thread)),
      .expect(
        #"{"method":"turn/started","params":{"threadId":"\#(thread)","turn":{"id":"\#(turnID)","status":"inProgress"}}}"#
      ),
      .expect(item("started", message, thread: thread, turn: turnID)),
      .expect(item("completed", message, thread: thread, turn: turnID)),
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

  /// The recorded logged-out turn, with one retry standing for the five the real CLI makes.
  static func fails(turn: String = "$turn") -> [HostMove] {
    let failure = #"""
      {"message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header",
       "codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":401}},"additionalDetails":null}
      """#
    return [
      .expect(
        #"""
        {"method":"error","params":{"threadId":"$thread","turnId":"\#(turn)","willRetry":true,
         "error":{"message":"Reconnecting... 1/5",
                  "codexErrorInfo":{"responseStreamDisconnected":{"httpStatusCode":401}}}}}
        """#),
      .expect(status(#"{"type":"systemError"}"#)),
      .expect(
        #"{"method":"error","params":{"threadId":"$thread","turnId":"\#(turn)","willRetry":false,"error":\#(failure)}}"#
      ),
      .expect(
        #"""
        {"method":"turn/completed",
         "params":{"threadId":"$thread","turn":{"id":"\#(turn)","status":"failed","error":\#(failure)}}}
        """#),
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
    let otherThread = "44444444-4444-4444-8444-444444444444"
    switch choice {
    case .approve: return answered(accept, approvedItem, approved)
    case .approveForSession: return forSession.map { answered($0, approvedItem, approved) }
    case .decline: return answered(decline, declinedItem, declined)
    case .interrupt:
      // An interrupt that names another thread or turn is refused, and the request stays open.
      return HostTranscript(
        moves: opening + [
          .send(
            #"{"id":5,"method":"turn/interrupt","params":{"threadId":"\#(otherThread)","turnId":"$turn"}}"#),
          .expect(#"{"id":5,"error":{"code":-32600,"message":"thread not found: \#(otherThread)"}}"#),
          .send(#"{"id":6,"method":"turn/interrupt","params":{"threadId":"$thread","turnId":"$thread"}}"#),
          .expect(#"{"id":6,"error":{"code":-32600,"message":"$*"}}"#),
          .send(#"{"id":7,"method":"turn/interrupt","params":{"threadId":"$thread","turnId":"$turn"}}"#),
          .expect(#"{"id":7,"result":{}}"#), .expect(resolved), .expect(status(#"{"type":"idle"}"#)),
          .expect(
            #"""
            {"method":"turn/completed","params":{"threadId":"$thread","turn":{"id":"$turn","status":"interrupted"}}}
            """#),
          .closeInput, .exit(0),
        ])
    case .main, .resume, .plainOutput, .idleControl, .answerOnStdio, .declineOnStdio, .interruptOnStdio:
      return nil
    }
  }
}
