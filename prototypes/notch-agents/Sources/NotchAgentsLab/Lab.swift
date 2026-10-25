import AppKit
import Observation
import SwiftUI

@Observable final class Lab {
  // Options
  var scope: DisplayScope = .pointer
  var backdrop: Backdrop = .plain
  var simulatedHeight: SimulatedHeight = .menuBar
  var idleOnNotchless: IdleOnNotchless = .nothing
  var forceNotchless = false { didSet { onLayoutChange?() } }
  var hover: HoverBehavior = .peek
  var hoverReach: HoverReach = .comfortable
  var showHoverZone = false
  var close: CloseBehavior = .clickOutside
  var working: WorkingIndicator = .dot
  var openMotion: OpenMotion = .snappy
  var panelLayout: PanelLayout = .drillIn
  var threadSize: ThreadSize = .roomy
  /// Scripted runs for screenshots never take keyboard focus.
  var passive = false
  var showTarget = true
  var slowMotion = false
  var reduceMotion = false

  // Scene
  var threads: [AgentThread] = Lab.seed()
  var dictation: Dictation = .off
  var levels: [CGFloat] = Array(repeating: 0, count: 16)
  var selectedThread: Int? = 1
  /// The thread drilled into from the list, when the layout drills in. Nil shows the list.
  var openThread: Int?
  var reply = ""
  /// The display whose surface is open or peeking. Only one at a time.
  private(set) var openScreen: ScreenID?
  private(set) var openLevel: Level = .idle
  var pointerScreen: ScreenID?

  /// The motion of the latest change, which the shape's reveal follows. Nil for changes that
  /// follow a key press and must not animate.
  @ObservationIgnored private(set) var shapeMotion: Animation? = Tokens.swap
  @ObservationIgnored var onLayoutChange: (() -> Void)?
  @ObservationIgnored var onOpenChange: ((ScreenID?, Level) -> Void)?
  /// Each thread works on its own, so a scenario, dictation and several agents never cancel
  /// each other.
  @ObservationIgnored private var scenario: Task<Void, Never>?
  @ObservationIgnored private var speech: Task<Void, Never>?
  @ObservationIgnored private var meter: Task<Void, Never>?
  @ObservationIgnored private var turns: [Int: Task<Void, Never>] = [:]
  /// What a thread does once its approval is answered.
  @ObservationIgnored private var afterApproval: [Int: Turn] = [:]
  @ObservationIgnored private var nextMessageID = 1000
  @ObservationIgnored private var peekedThread: Int?

  // MARK: Derived

  /// The threads the closed notch shows, most urgent first. Working threads are not here.
  var attentionThreads: [AgentThread] {
    threads.filter(\.wantsAttention).sorted {
      ($0.state.rank, $0.updated) > ($1.state.rank, $1.updated)
    }
  }

  /// The thread the closed notch speaks for, when dictation is not using it.
  var primaryThread: AgentThread? { attentionThreads.first }

  func thread(_ id: Int?) -> AgentThread? { threads.first { $0.id == id } }

  /// The open shape is wider once you are inside a thread, so the growth says where you went.
  var panelWidth: CGFloat {
    panelLayout == .drillIn && openThread != nil ? threadSize.width : Tokens.panelWidth
  }

  var conversationMaxHeight: CGFloat {
    let usable = NSScreen.screens.first { $0.screenID == openScreen }?.visibleFrame.height ?? 900
    return (usable * threadSize.heightShare).rounded()
  }

  func shows(on screen: NSScreen) -> Bool {
    switch scope {
    case .withMenuBar: screen.hasMenuBar
    case .all: true
    case .main: screen == NSScreen.main
    case .pointer: screen.screenID == pointerScreen
    }
  }

  func level(on screen: NSScreen) -> Level {
    if openScreen == screen.screenID, openLevel != .idle { return openLevel }
    guard shows(on: screen) else { return .idle }
    return dictation != .off || primaryThread != nil ? .status : .idle
  }

  func animation(_ base: Animation) -> Animation {
    let base = reduceMotion ? .easeInOut(duration: 0.2) : base
    return slowMotion ? base.speed(0.25) : base
  }

  /// Every scene change goes through here, so the shape's reveal uses the same motion.
  func animate(_ base: Animation, _ change: () -> Void) {
    shapeMotion = animation(base)
    withAnimation(shapeMotion, change)
  }

  // MARK: Opening

  func open(_ level: Level, on screen: ScreenID, fromKeyboard: Bool = false) {
    guard openScreen != screen || openLevel != level else { return }
    let growing = level == .expanded || (level == .peek && openLevel == .idle)
    let wasExpanded = openLevel == .expanded
    let motion = fromKeyboard ? Tokens.instant : growing ? openMotion.animation : Tokens.close
    if openLevel == .peek { markPeekSeen() }
    if level == .peek { peekedThread = primaryThread?.id }
    animate(motion) {
      openScreen = level == .idle ? nil : screen
      openLevel = level
      // Opening lands on the thread the closed notch was speaking for, at list depth.
      if level == .expanded, !wasExpanded {
        selectedThread = primaryThread?.id ?? selectedThread ?? threads.first?.id
        // With one thread asking for attention there is nothing to choose, so open it directly.
        openThread = panelLayout == .drillIn && attentionThreads.count == 1 ? primaryThread?.id : nil
        if let openThread { markSeen(openThread) }
      }
    }
    onOpenChange?(openScreen, openLevel)
  }

  func closeAll(fromKeyboard: Bool = false) {
    guard openScreen != nil else { return }
    if openLevel == .peek { markPeekSeen() }
    animate(fromKeyboard ? Tokens.instant : Tokens.close) {
      openScreen = nil
      openLevel = .idle
      openThread = nil
    }
    onOpenChange?(nil, .idle)
  }

  /// The O key in the lab, standing in for a global shortcut: near-instant both ways.
  func toggleOpen() {
    if openLevel == .expanded {
      closeAll(fromKeyboard: true)
    } else {
      let id = pointerScreen ?? NSScreen.main?.screenID ?? 0
      open(.expanded, on: id, fromKeyboard: true)
    }
  }

  /// Opens the panel straight into one thread, for a click on the closed notch's thread.
  func show(thread id: Int) {
    selectedThread = id
    markSeen(id)
    animate(openMotion.animation) { openThread = id }
  }

  func back(fromKeyboard: Bool = false) {
    animate(fromKeyboard ? Tokens.instant : Tokens.close) { openThread = nil }
  }

  /// Esc steps back one level: thread to list, list to closed.
  func escape() {
    if openThread != nil, panelLayout == .drillIn { back(fromKeyboard: true) } else { closeAll(fromKeyboard: true) }
  }

  // MARK: Dictation

  /// Hold to talk. Agent mode sends the speech to the selected thread instead of pasting it.
  func press(agentMode: Bool) {
    if case .recording = dictation { return }
    speech?.cancel()
    // Recording feedback never animates in: it follows a key press and happens many times a day.
    shapeMotion = nil
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      dictation = .recording(thread: agentMode ? (openThread ?? selectedThread ?? threads.first?.id) : nil)
    }
    startMeter()
  }

  func release() {
    guard case .recording(let target) = dictation else { return }
    stopMeter()
    swap { dictation = .transcribing(thread: target) }
    speech = Task {
      try? await pause(0.45)
      guard !Task.isCancelled else { return }
      swap { dictation = target.map { .sent(thread: $0) } ?? .pasted }
      if let target { start(target, Lab.voiceTurn) }
      try? await pause(1.1)
      guard !Task.isCancelled else { return }
      animate(Tokens.hide) { dictation = .off }
    }
  }

  private func startMeter() {
    meter?.cancel()
    meter = Task {
      var phase = 0.0
      while !Task.isCancelled {
        phase += 0.35
        let next = (0..<16).map { index -> CGFloat in
          let wave = (sin(phase + Double(index) * 0.55) + 1) / 2
          return CGFloat(0.15 + 0.85 * wave * Double.random(in: 0.55...1))
        }
        withAnimation(.linear(duration: 0.05)) { levels = next }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func stopMeter() {
    meter?.cancel()
    levels = Array(repeating: 0, count: 16)
  }

  // MARK: Turns

  /// One prompt and the agent's work on it.
  struct Turn {
    var prompt: String?
    var steps: [String]
    var approval: Approval?
    var reply: String
    var end: ThreadState
  }

  func start(_ id: Int, _ turn: Turn) {
    turns[id]?.cancel()
    turns[id] = Task { await run(id, turn) }
  }

  private func run(_ id: Int, _ turn: Turn) async {
    if let prompt = turn.prompt {
      swap { append(id, .user, prompt) }
    }
    swap { update(id) { $0.state = .working("Thinking") } }
    for step in turn.steps {
      try? await pause(1.1)
      guard !Task.isCancelled else { return }
      swap {
        update(id) { $0.state = .working(step) }
        append(id, .tool, step)
      }
    }
    if let approval = turn.approval {
      try? await pause(0.8)
      guard !Task.isCancelled else { return }
      var rest = turn
      rest.prompt = nil
      rest.approval = nil
      rest.steps = ["Ran \(approval.command)"]
      afterApproval[id] = rest
      animate(Tokens.grow) { update(id) { $0.state = .needsYou(approval) } }
      return
    }
    try? await pause(0.9)
    guard !Task.isCancelled else { return }
    if case .failed = turn.end {
      swap {
        append(id, .tool, turn.reply)
        update(id) { $0.state = turn.end }
      }
      return
    }
    swap { update(id) { $0.state = .working("Writing") } }
    await stream(id, turn.reply)
    guard !Task.isCancelled else { return }
    swap { update(id) { $0.state = turn.end } }
  }

  /// Appends the reply a few words at a time, the way a streamed answer arrives.
  private func stream(_ id: Int, _ text: String) async {
    append(id, .agent, "")
    var shown = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: false) {
      try? await Task.sleep(for: .milliseconds(slowMotion ? 120 : 30))
      guard !Task.isCancelled else { return }
      shown += shown.isEmpty ? String(word) : " " + word
      update(id) { $0.messages[$0.messages.count - 1].text = shown }
    }
  }

  func approve(_ id: Int, always: Bool = false) {
    guard var rest = afterApproval.removeValue(forKey: id) else { return }
    swap { append(id, .tool, always ? "Allowed for this thread" : "Allowed once") }
    rest.prompt = nil
    start(id, rest)
  }

  func deny(_ id: Int) {
    afterApproval[id] = nil
    swap { append(id, .tool, "Denied") }
    start(
      id,
      Turn(
        prompt: nil, steps: [], approval: nil,
        reply: "OK, I won't run it. Tell me how you'd like to check the change instead.",
        end: .done("Waiting for you")))
  }

  func sendReply() {
    guard let id = openThread ?? selectedThread, !reply.isEmpty else { return }
    let text = reply
    reply = ""
    start(
      id,
      Turn(
        prompt: text, steps: ["Read 2 files"], approval: nil,
        reply: "Done. I looked at the two files you mentioned and the change is in place.",
        end: .done("Answered")))
  }

  func newThread() {
    let id = (threads.map(\.id).max() ?? 0) + 1
    swap {
      threads.append(
        AgentThread(
          id: id, title: "New thread", project: "openvocally", provider: .claude, state: .idle,
          messages: [], updated: .now))
      selectedThread = id
      if panelLayout == .drillIn { openThread = id }
    }
  }

  private func update(_ id: Int, _ change: (inout AgentThread) -> Void) {
    guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
    let wasDone = Self.isDone(threads[index].state)
    change(&threads[index])
    threads[index].updated = .now
    // A thread that just finished waits in the closed notch until you look at it.
    if !wasDone, Self.isDone(threads[index].state) { threads[index].seen = false }
  }

  private static func isDone(_ state: ThreadState) -> Bool {
    if case .done = state { return true }
    return false
  }

  /// Peeking at a finished thread counts as looking at it, once the peek closes, so the line
  /// never vanishes while you read it.
  private func markPeekSeen() {
    if let peekedThread { markSeen(peekedThread) }
    peekedThread = nil
  }

  private func markSeen(_ id: Int) {
    guard let index = threads.firstIndex(where: { $0.id == id }), !threads[index].seen else { return }
    animate(Tokens.swap) { threads[index].seen = true }
  }

  private func append(_ id: Int, _ role: Role, _ text: String) {
    nextMessageID += 1
    let message = Message(id: nextMessageID, role: role, text: text)
    update(id) { $0.messages.append(message) }
  }

  private func swap(_ change: () -> Void) {
    animate(Tokens.swap, change)
  }

  private func pause(_ seconds: Double) async throws {
    try await Task.sleep(for: .seconds(seconds * (slowMotion ? 4 : 1)))
  }

  // MARK: Scenarios

  enum Scenario: String, CaseIterable, Identifiable {
    case answer = "Agent answers"
    case needsYou = "Thread needs you"
    case twoNeedYou = "Two need you"
    case busy = "Three threads"
    case interrupt = "Needs you during dictation"
    case failed = "Thread fails"
    case many = "Eight threads, long names"
    case reset = "Reset"
    var id: Self { self }
  }

  func play(_ scenario: Scenario) {
    self.scenario?.cancel()
    self.scenario = Task {
      switch scenario {
      case .reset:
        reset()
      case .answer:
        start(1, Lab.answerTurn)
      case .needsYou:
        start(1, Lab.testTurn)
      case .twoNeedYou:
        start(2, Lab.appcastTurn)
        try? await pause(1.2)
        guard !Task.isCancelled else { return }
        start(3, Lab.siteTurn)
      case .busy:
        start(1, Lab.answerTurn)
        start(2, Turn(prompt: "Open a pull request", steps: ["Pushed the branch"], approval: nil,
          reply: "Opened **Update the appcast for 1.0.4**. CI is running.", end: .done("Opened a pull request")))
        try? await pause(1.5)
        guard !Task.isCancelled else { return }
        start(3, Lab.siteTurn)
      case .interrupt:
        press(agentMode: false)
        try? await pause(0.6)
        guard !Task.isCancelled else { return }
        start(2, Lab.appcastTurn)
        try? await pause(3.2)
        guard !Task.isCancelled else { return }
        release()
      case .failed:
        start(
          2,
          Turn(
            prompt: "Regenerate the appcast", steps: ["Ran make appcast"], approval: nil,
            reply: "codex exited with code 1: not logged in", end: .failed("Not logged in")))
      case .many:
        reset()
        let extra: [(String, String, ThreadState)] = [
          ("Rewrite the onboarding permission step so it explains why we need Accessibility", "openvocally", .working("Editing OnboardingView.swift")),
          ("Investigate the clipped first word on Bluetooth headsets", "openvocally", .needsYou(Lab.approval)),
          ("Bump FluidAudio", "openvocally", .done("Tests pass")),
          ("Kopia zapasowa ustawień — przetłumacz komunikaty błędów", "site", .working("Thinking")),
          ("x", "site", .failed("Session ended")),
        ]
        for (offset, item) in extra.enumerated() {
          threads.append(
            AgentThread(
              id: 10 + offset, title: item.0, project: item.1, provider: offset.isMultiple(of: 2) ? .claude : .codex,
              state: item.2, messages: [Message(id: 500 + offset, role: .agent, text: "Working on it.")],
              updated: .now.addingTimeInterval(Double(-offset * 90))))
        }
        start(1, Lab.answerTurn)
      }
    }
  }

  private func reset() {
    for turn in turns.values { turn.cancel() }
    turns = [:]
    afterApproval = [:]
    speech?.cancel()
    stopMeter()
    animate(Tokens.hide) {
      threads = Lab.seed()
      dictation = .off
      openThread = nil
    }
    closeAll()
  }

  // MARK: Content

  static let approval = Approval(title: "Run a command?", command: "swift test --filter Overlay")

  static let voiceTurn = Turn(
    prompt: "Run the tests again and fix what fails.",
    steps: ["Ran swift test", "Edited PasteController.swift"], approval: nil,
    reply: "Fixed. One test failed because the paste waited for a clipboard change that never came. I now restore the clipboard after **150 ms** instead of waiting. All 42 tests pass.",
    end: .done("Tests pass"))

  static let answerTurn = Turn(
    prompt: "Why is paste slow after long dictations?",
    steps: ["Read PasteController.swift", "Searched for pasteDelay", "Ran swift test --filter Paste"],
    approval: nil,
    reply: """
      The delay grows with the text because `PasteController` waits for the clipboard to settle before it sends ⌘V, and it polls every 50 ms.

      **What I found**
      - Long transcripts take a second poll on slower apps, so you wait 100 ms more.
      - The wait isn't needed when the target app is frontmost, which it always is here.

      **What I suggest**
      Send ⌘V right after writing the clipboard, and restore it once the paste lands. That removes the poll entirely. Want me to make the change?
      """,
    end: .done("Answered"))

  static let testTurn = Turn(
    prompt: "Make the overlay tests pass on macOS 15.",
    steps: ["Read OverlayTests.swift", "Edited NotchView.swift"], approval: approval,
    reply: "All 18 overlay tests pass on macOS 15. The failure was a hard-coded notch height; it now comes from `NSScreen`.",
    end: .done("Tests pass"))

  static let appcastTurn = Turn(
    prompt: "Publish the appcast for 1.0.4.",
    steps: ["Read appcast.xml"], approval: Approval(title: "Push to origin?", command: "git push origin main"),
    reply: "Pushed. The feed now lists 1.0.4.", end: .done("Pushed"))

  static let siteTurn = Turn(
    prompt: "Tighten the hero copy.",
    steps: ["Read index.html"], approval: Approval(title: "Edit a file outside the project?", command: "~/site/copy.md"),
    reply: "Shortened the headline to six words and cut the second paragraph.", end: .done("Copy updated"))

  static func seed() -> [AgentThread] {
    [
      AgentThread(
        id: 1, title: "Fix the paste delay", project: "openvocally", provider: .claude, state: .idle,
        messages: [
          Message(id: 1, role: .user, text: "Measure the paste latency on the en-short fixture."),
          Message(id: 2, role: .tool, text: "Ran make dictation-harness"),
          Message(id: 3, role: .agent, text: "Release to paste is **212 ms** median over 10 runs, inside the 250 ms budget. The slowest run was 248 ms."),
        ],
        updated: .now.addingTimeInterval(-600)),
      AgentThread(
        id: 2, title: "Update the appcast", project: "openvocally", provider: .codex, state: .idle,
        messages: [
          Message(id: 4, role: .user, text: "Prepare 1.0.4."),
          Message(id: 5, role: .agent, text: "Bumped the version and wrote the release notes."),
        ],
        updated: .now.addingTimeInterval(-3600)),
      AgentThread(
        id: 3, title: "Landing page copy", project: "site", provider: .claude, state: .idle,
        messages: [
          Message(id: 6, role: .user, text: "Draft three headlines."),
          Message(id: 7, role: .agent, text: "1. Talk. It types.\n2. Dictation that stays on your Mac.\n3. Hold a key, speak, done."),
        ],
        updated: .now.addingTimeInterval(-7200)),
    ]
  }
}
