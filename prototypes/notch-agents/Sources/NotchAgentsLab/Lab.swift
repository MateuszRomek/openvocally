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
  var arrival: ApprovalArrival = .card
  var approvalQueue: ApprovalQueue = .oneAtATime
  var commandLength: CommandLength = .full
  var allowPlacement: AllowPlacement = .menu
  var cardLinger: CardLinger = .shrinks
  var voiceTarget: VoiceTarget = .card
  var cardLook: CardLook = .calm
  var pickerKeys: PickerKeys = .numbered
  /// Left ⌘ is down, so the card shows its shortcuts. Right ⌘ is agent mode and never shows them.
  var shortcutsHeld = false
  var promptStyle: PromptStyle = .field
  var draftMark: DraftMark = .word
  var newThreadKeyBehavior: NewThreadKey = .card
  var respeak: Respeak = .replace
  var draftOnNew: DraftOnNew = .reopen

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
  /// Threads waiting on an approval, oldest request first.
  private(set) var approvalOrder: [Int] = []
  /// Approvals the notch shrank back to the Needs you mark. They are still pending.
  private(set) var collapsedCards: Set<Int> = []
  /// The card shown when the queue shows one at a time.
  var cardIndex = 0
  /// A key answer arrived while no card was on screen, so the card came back first.
  private(set) var keyRevealed = false

  // Start card
  /// The new thread being set up. Survives clicking away, as the draft mark.
  var draft: StartDraft?
  /// The picker whose list shows in the card.
  var openControl: CardControl?
  /// The chip Tab moved to. Nil is the prompt.
  var focusedControl: CardControl?
  var highlight = 0
  var filter = ""
  var editingPrompt = false
  /// Key presses since the card opened, to compare how fast each key scheme is.
  var cardKeys = 0
  /// ⌥T in the target-only variant: the next agent recording starts a new thread.
  var newThreadArmed = false
  /// Speech for the card is being transcribed; the prompt shows that in its own place.
  var transcribingIntoCard = false
  var lastSettings = Lab.firstSettings
  var lastByProject = Lab.projectSettings
  var lastByProvider: [Provider: ThreadSettings] = [:]

  /// The motion of the latest change, which the shape's reveal follows. Nil for changes that
  /// follow a key press and must not animate.
  @ObservationIgnored private(set) var shapeMotion: Animation? = Tokens.swap
  /// Until then, the shape is moving between levels, and content changes keep its motion. Without
  /// this, a thread's first update right after a card closes would swap the morph's spring mid-flight.
  @ObservationIgnored private var levelMotionUntil = Date.distantPast
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
  /// Threads opened while the panel was open; closing the panel shrinks their cards away.
  @ObservationIgnored private var viewedThisOpen: Set<Int> = []

  // MARK: Derived

  /// The threads the closed notch shows, most urgent first. Working threads are not here.
  var attentionThreads: [AgentThread] {
    threads.filter(\.wantsAttention).sorted {
      ($0.state.rank, $0.updated) > ($1.state.rank, $1.updated)
    }
  }

  /// The thread the closed notch speaks for, when dictation is not using it.
  /// With an approval card showing, that is the card's thread, so the glyph beside the camera
  /// matches the card below it.
  var primaryThread: AgentThread? {
    if showsCard, let front = thread(frontApproval) { return front }
    return attentionThreads.first
  }

  func thread(_ id: Int?) -> AgentThread? { threads.first { $0.id == id } }

  /// The pending approvals the notch still shows as cards.
  var cardThreads: [Int] { approvalOrder.filter { !collapsedCards.contains($0) } }

  var frontApproval: Int? {
    let ids = cardThreads
    return ids.isEmpty ? nil : ids[min(cardIndex, ids.count - 1)]
  }

  /// Whether the closed notch grows into the approval card. Plain dictation keeps the notch to
  /// itself, so a card that arrives mid-sentence waits until the text is pasted.
  var showsCard: Bool {
    guard arrival != .mark || keyRevealed, let front = frontApproval else { return false }
    switch dictation {
    // A start card that just closed hands its shape straight to the waiting approval; the
    // top row's "Started" or "Discarded" crossfades meanwhile instead of holding the card back.
    case .off, .started, .discarded: return true
    case .recording(let id): return id == front
    default: return false
    }
  }

  /// Where agent mode sends speech: the open thread, else the card's thread, else the selection.
  var agentTarget: Int? {
    if openLevel == .start || newThreadArmed { return Lab.newThreadTarget }
    if let openThread { return openThread }
    if voiceTarget == .card, openLevel == .idle, showsCard, let front = frontApproval { return front }
    return selectedThread ?? threads.first?.id
  }

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
    if showsCard { return .approval }
    // A card open on another display is shown there only.
    let draftShows = draft != nil && openLevel != .start
    return dictation != .off || primaryThread != nil || draftShows || newThreadArmed ? .status : .idle
  }

  func animation(_ base: Animation) -> Animation {
    let base = reduceMotion ? .easeInOut(duration: 0.2) : base
    return slowMotion ? base.speed(0.25) : base
  }

  /// Every scene change goes through here, so the shape's reveal uses the same motion. A change of
  /// level owns the shape's motion while it runs; anything else animates only its content then.
  func animate(_ base: Animation, levelChange: Bool = false, _ change: () -> Void) {
    if levelChange {
      levelMotionUntil = .now.addingTimeInterval(slowMotion ? 1.6 : 0.4)
    } else if Date.now < levelMotionUntil {
      withAnimation(animation(base), change)
      return
    }
    shapeMotion = animation(base)
    withAnimation(shapeMotion, change)
  }

  // MARK: Opening

  /// `thread` opens the panel straight into that thread, for a click on its approval card.
  func open(_ level: Level, on screen: ScreenID, fromKeyboard: Bool = false, thread: Int? = nil) {
    guard openScreen != screen || openLevel != level else { return }
    let growing = level == .expanded || level == .start || (level == .peek && openLevel == .idle)
    let wasExpanded = openLevel == .expanded
    let motion = fromKeyboard ? Tokens.instant : growing ? openMotion.animation : Tokens.close
    if openLevel == .peek { markPeekSeen() }
    if level == .peek { peekedThread = primaryThread?.id }
    animate(motion, levelChange: true) {
      openScreen = level == .idle ? nil : screen
      openLevel = level
      // Opening lands on the thread the closed notch was speaking for, at list depth.
      if level == .expanded, !wasExpanded, let thread {
        selectedThread = thread
        openThread = panelLayout == .drillIn ? thread : nil
        viewedThisOpen.insert(thread)
        markSeen(thread)
      } else if level == .expanded, !wasExpanded {
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
    let viewed = viewedThisOpen.intersection(approvalOrder)
    viewedThisOpen = []
    animate(fromKeyboard ? Tokens.instant : Tokens.close, levelChange: true) {
      // You looked at these in the panel, so the notch doesn't grow them back as you close it.
      collapsedCards.formUnion(viewed)
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
    viewedThisOpen.insert(id)
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
    levelMotionUntil = .distantPast
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      dictation = .recording(thread: agentMode ? agentTarget : nil)
    }
    startMeter()
  }

  func release() {
    guard case .recording(let target) = dictation else { return }
    stopMeter()
    if target == Lab.newThreadTarget {
      // Release already decided where the words go, so the card opens now and transcribes inside
      // itself: one growth, and the text lands where the placeholder was.
      speechIntoCard()
      speech = Task {
        try? await pause(0.45)
        guard !Task.isCancelled else { return }
        swap { receiveSpeech() }
      }
      return
    }
    swap { dictation = .transcribing(thread: target) }
    speech = Task {
      try? await pause(0.45)
      guard !Task.isCancelled else { return }
      if target == nil, openLevel == .start {
        // Plain dictation pastes into the focused card like any text field.
        pasteIntoCard()
        swap { dictation = .pasted }
        try? await pause(1.1)
        guard !Task.isCancelled else { return }
        animate(Tokens.hide) { dictation = .off }
        return
      }
      if let target, approvalOrder.contains(target) {
        // Voice never approves: speaking while an approval waits denies it, with what you said.
        swap { dictation = .deniedWithReason(thread: target) }
        deny(target, reason: Lab.spokenReason)
        try? await pause(1.8)
        guard !Task.isCancelled else { return }
        animate(Tokens.hide) { dictation = .off }
        return
      }
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
      animate(openMotion.animation, levelChange: true) {
        update(id) { $0.state = .needsYou(approval) }
        approvalOrder.append(id)
      }
      scheduleCollapse(id)
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
    guard approvalOrder.contains(id) else { return }
    var rest =
      afterApproval.removeValue(forKey: id)
      ?? Turn(prompt: nil, steps: [], approval: nil, reply: "Done.", end: .done("Done"))
    animate(Tokens.close, levelChange: true) {
      settle(id)
      append(id, .tool, always ? "Allowed for this thread" : "Allowed once")
    }
    rest.prompt = nil
    start(id, rest)
  }

  /// `reason` is what you typed or said instead of answering; the agent gets it as the next message.
  func deny(_ id: Int, reason: String? = nil) {
    guard approvalOrder.contains(id) else { return }
    afterApproval[id] = nil
    animate(Tokens.close, levelChange: true) {
      settle(id)
      append(id, .tool, reason == nil ? "Denied" : "Denied, sent your reply as the reason")
    }
    start(
      id,
      Turn(
        prompt: reason, steps: [], approval: nil,
        reply: reason == nil
          ? "OK, I won't run it. Tell me how you'd like to check the change instead."
          : "Understood. I won't run it, and I'll use `make test` instead.",
        end: .done("Waiting for you")))
  }

  /// ⌥↩ and ⌥⎋ from any app. They answer only a card you can see: with no card on screen, the
  /// first press brings the oldest one back, so a key never approves something off screen.
  func answerFromKeyboard(allow: Bool) {
    guard !approvalOrder.isEmpty, openLevel == .idle else { return }
    let hidden = !showsCard || (arrival == .peek && !keyRevealed)
    if hidden {
      animate(Tokens.instant) {
        if let first = approvalOrder.first {
          collapsedCards.remove(first)
          cardIndex = cardThreads.firstIndex(of: first) ?? 0
        }
        keyRevealed = true
      }
      return
    }
    guard let front = frontApproval else { return }
    allow ? approve(front) : deny(front)
  }

  private func settle(_ id: Int) {
    approvalOrder.removeAll { $0 == id }
    collapsedCards.remove(id)
    cardIndex = min(cardIndex, max(cardThreads.count - 1, 0))
    if approvalOrder.isEmpty { keyRevealed = false }
  }

  /// A peek line always shrinks back; a card does only when the lab says so.
  private func scheduleCollapse(_ id: Int) {
    let seconds: Double? = arrival == .peek ? 4 : cardLinger == .shrinks ? 8 : nil
    guard let seconds, arrival != .mark else { return }
    Task {
      try? await pause(seconds)
      guard approvalOrder.contains(id), !keyRevealed else { return }
      animate(Tokens.close, levelChange: true) { collapsedCards.insert(id) }
    }
  }

  func sendReply() {
    guard let id = openThread ?? selectedThread, !reply.isEmpty else { return }
    let text = reply
    reply = ""
    if approvalOrder.contains(id) {
      deny(id, reason: text)
      return
    }
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

  func swap(_ change: () -> Void) {
    animate(Tokens.swap, change)
  }

  func pause(_ seconds: Double) async throws {
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
    case threeApprovals = "Three approvals"
    case longCommand = "Long command"
    case riskyTail = "Risky tail"
    case speakNew = "Speak a new thread"
    case speakAgain = "Speak again into the card"
    case approvalDuringCard = "Approval while the card is open"
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
      case .threeApprovals:
        start(1, Lab.testTurn)
        try? await pause(0.6)
        guard !Task.isCancelled else { return }
        start(2, Lab.appcastTurn)
        try? await pause(0.6)
        guard !Task.isCancelled else { return }
        start(3, Lab.siteTurn)
      case .longCommand:
        start(1, Lab.longTurn)
      case .approvalDuringCard:
        // The card opens, then a running thread asks for approval while you're still in it.
        newThreadArmed = true
        press(agentMode: true)
        try? await pause(1.8)
        guard !Task.isCancelled else { return }
        release()
        try? await pause(1)
        guard !Task.isCancelled else { return }
        start(1, Lab.testTurn)
      case .speakNew, .speakAgain:
        // Agent mode with a new thread as the target: hold, talk, release.
        if scenario == .speakNew, openLevel != .start { newThreadArmed = true }
        press(agentMode: true)
        try? await pause(1.8)
        guard !Task.isCancelled else { return }
        release()
      case .riskyTail:
        start(2, Lab.tailTurn)
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
        approvalOrder.append(11)
        start(1, Lab.answerTurn)
      }
    }
  }

  private func reset() {
    for turn in turns.values { turn.cancel() }
    turns = [:]
    afterApproval = [:]
    approvalOrder = []
    collapsedCards = []
    cardIndex = 0
    keyRevealed = false
    speech?.cancel()
    stopMeter()
    animate(Tokens.hide) {
      threads = Lab.seed()
      dictation = .off
      openThread = nil
      draft = nil
      newThreadArmed = false
      lastSettings = Lab.firstSettings
      lastByProject = Lab.projectSettings
      lastByProvider = [:]
    }
    closeAll()
  }

  // MARK: Content

  static let approval = Approval(
    title: "Run a command?", command: "swift test --filter Overlay",
    reason: "Check the notch height fix against the overlay tests", detail: "~/dev/openvocally")

  /// What the lab pretends you said while an approval waited.
  static let spokenReason = "No, use make test, it sets up the fixtures."

  static let longTurn = Turn(
    prompt: "Run the overlay and paste tests in Xcode.",
    steps: ["Read project.yml"],
    approval: Approval(
      title: "Run a command?",
      command: """
        xcodebuild test \\
          -scheme OpenVocally \\
          -configuration Debug \\
          -derivedDataPath .build/xcode \\
          -only-testing:OpenVocallyTests/OverlayTests \\
          -only-testing:OpenVocallyTests/PasteControllerTests \\
          -destination 'platform=macOS,arch=arm64' \\
          2>&1 | tee .build/test.log | xcbeautify
        """,
      reason: "Run both suites the fix touches", detail: "~/dev/openvocally"),
    reply: "Both suites pass: 18 overlay tests and 9 paste tests.", end: .done("Tests pass"))

  /// A command whose dangerous part is at the end, where a one-line truncation hides it.
  static let tailTurn = Turn(
    prompt: "Install the release build so I can test the updater.",
    steps: ["Read Makefile"],
    approval: Approval(
      title: "Run a command?",
      command: "swift build -c release --product OpenVocally && cp -R .build/release/OpenVocally.app /Applications/ && rm -rf ~/Library/Application\\ Support/com.openvocally.app",
      reason: "Start the updater test from a clean install", detail: "~/dev/openvocally"),
    reply: "Installed. The app starts with no saved settings.", end: .done("Installed"))

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
    steps: ["Read appcast.xml"], approval: Approval(
      title: "Run a command?", command: "git push origin main", reason: "Publish the 1.0.4 feed",
      detail: "~/dev/openvocally"),
    reply: "Pushed. The feed now lists 1.0.4.", end: .done("Pushed"))

  static let siteTurn = Turn(
    prompt: "Tighten the hero copy.",
    steps: ["Read index.html"], approval: Approval(
      kind: .edit, title: "Edit a file outside the project?", command: "~/site/copy.md",
      reason: "The hero copy lives in the site folder", detail: "+12 −4"),
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
