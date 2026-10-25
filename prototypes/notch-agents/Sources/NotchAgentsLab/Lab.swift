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
  var questionLayout: QuestionLayout = .stepped
  var optionStyle: OptionStyle = .rows
  var optionKeys: OptionKeys = .option
  var questionLinger: QuestionLinger = .likeApprovals
  var lastingFirst: LastingFirst = .lasting
  var formPlacement: FormPlacement = .choicesInline

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
  /// The question each card shows when questions come one at a time.
  var questionStep: [Int: Int] = [:]
  /// Picked options per thread, by question index.
  var picks: [Int: [Int: Set<Int>]] = [:]
  /// Answers in your own words per thread, by question index: speech or a typed reply.
  var ownWords: [Int: [Int: String]] = [:]
  /// Form values per thread, by field index.
  var formValues: [Int: [Int: String]] = [:]
  /// Sign-in links you opened, waiting for the server to say you finished.
  private(set) var linksOpened: Set<Int> = []

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
    case .off: return true
    case .recording(let id): return id == front
    default: return false
    }
  }

  /// Where agent mode sends speech: the open thread, else the card's thread, else the selection.
  var agentTarget: Int? {
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

  /// `thread` opens the panel straight into that thread, for a click on its approval card.
  func open(_ level: Level, on screen: ScreenID, fromKeyboard: Bool = false, thread: Int? = nil) {
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
    animate(fromKeyboard ? Tokens.instant : Tokens.close) {
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
    swap { dictation = .transcribing(thread: target) }
    speech = Task {
      try? await pause(0.45)
      guard !Task.isCancelled else { return }
      if let target, approvalOrder.contains(target), pendingApproval(target)?.isQuestion == true {
        // Speech is the free-text answer to the question on screen, sent word for word.
        swap { dictation = .answeredBySpeech(thread: target) }
        answerByText(target, Lab.spokenAnswer)
        try? await pause(1.8)
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
      rest.steps = Lab.stepAfter(approval)
      afterApproval[id] = rest
      animate(openMotion.animation) {
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

  func approve(_ id: Int, grant: Grant = .once) {
    finish(id, record: grant.record)
  }

  /// Answers the request and lets the thread carry on with the rest of its turn.
  private func finish(_ id: Int, record: String) {
    guard approvalOrder.contains(id) else { return }
    var rest =
      afterApproval.removeValue(forKey: id)
      ?? Turn(prompt: nil, steps: [], approval: nil, reply: "Done.", end: .done("Done"))
    animate(Tokens.close) {
      settle(id)
      append(id, .tool, record)
    }
    rest.prompt = nil
    start(id, rest)
  }

  func pendingApproval(_ id: Int?) -> Approval? {
    if let thread = thread(id), case .needsYou(let approval) = thread.state { return approval }
    return nil
  }

  // MARK: Questions

  /// The question a card shows now. With every question on the card, it is the first unanswered.
  func currentQuestion(_ id: Int) -> Int {
    let count = pendingApproval(id)?.questions.count ?? 0
    return min(questionStep[id] ?? 0, max(count - 1, 0))
  }

  func isPicked(_ id: Int, question: Int, option: Int) -> Bool {
    picks[id]?[question]?.contains(option) ?? false
  }

  /// A click or ⌥ digit. A single-select pick answers its question at once and moves on.
  func pick(_ id: Int, question: Int, option: Int) {
    guard let questions = pendingApproval(id)?.questions, questions.indices.contains(question) else { return }
    var chosen = picks[id]?[question] ?? []
    if questions[question].multiSelect {
      if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
      animate(Tokens.swap) { picks[id, default: [:]][question] = chosen }
      return
    }
    animate(Tokens.swap) { picks[id, default: [:]][question] = [option] }
    advance(id, from: question)
  }

  /// Next for a multi-select question, or Submit once every question has an answer.
  func advance(_ id: Int, from question: Int) {
    guard let questions = pendingApproval(id)?.questions else { return }
    let answered = questions.indices.allSatisfy { !(picks[id]?[$0] ?? []).isEmpty || ownWords[id]?[$0] != nil }
    if questionLayout == .stepped, question < questions.count - 1 {
      animate(Tokens.swap) { questionStep[id] = question + 1 }
    } else if answered {
      submitQuestions(id)
    }
  }

  func stepQuestion(_ id: Int, by offset: Int) {
    let count = pendingApproval(id)?.questions.count ?? 0
    animate(Tokens.swap) { questionStep[id] = min(max(currentQuestion(id) + offset, 0), count - 1) }
  }

  func canSubmit(_ id: Int) -> Bool {
    guard let questions = pendingApproval(id)?.questions else { return false }
    return questions.indices.allSatisfy { !(picks[id]?[$0] ?? []).isEmpty || ownWords[id]?[$0] != nil }
  }

  func submitQuestions(_ id: Int) {
    guard let questions = pendingApproval(id)?.questions else { return }
    let labels = questions.indices.flatMap { index in
      ownWords[id]?[index].map { _ in ["your words"] }
        ?? (picks[id]?[index] ?? []).sorted().map { questions[index].options[$0].label }
    }
    finish(id, record: "Answered: \(labels.joined(separator: ", "))")
  }

  /// Speech or a typed reply is the free-text answer to the question on screen, sent word for
  /// word. The card moves on to the next question, and the call ends after the last.
  func answerByText(_ id: Int, _ text: String) {
    guard approvalOrder.contains(id) else { return }
    let question = currentQuestion(id)
    animate(Tokens.swap) {
      ownWords[id, default: [:]][question] = text
      picks[id, default: [:]][question] = nil
    }
    advance(id, from: question)
  }

  /// Skip declines the question; the agent carries on without an answer.
  func skip(_ id: Int) {
    guard approvalOrder.contains(id) else { return }
    afterApproval[id] = nil
    animate(Tokens.close) {
      settle(id)
      append(id, .tool, "Skipped the question")
    }
    start(
      id,
      Turn(
        prompt: nil, steps: [], approval: nil,
        reply: "No problem. I went with the first option for now; tell me if you want it changed.",
        end: .done("Waiting for you")))
  }

  // MARK: Forms and links

  func setField(_ id: Int, field: Int, value: String) {
    animate(Tokens.swap) { formValues[id, default: [:]][field] = value }
  }

  func canSubmitForm(_ id: Int) -> Bool {
    guard case .form(_, let fields) = pendingApproval(id)?.kind else { return false }
    return fields.indices.allSatisfy { !fields[$0].required || !(formValues[id]?[$0] ?? "").isEmpty }
  }

  func submitForm(_ id: Int) {
    guard canSubmitForm(id) else { return }
    finish(id, record: "Sent the form")
  }

  /// Opening the link answers nothing yet: the server says when you finished in the browser.
  func openLink(_ id: Int) {
    guard approvalOrder.contains(id), !linksOpened.contains(id) else { return }
    animate(Tokens.swap) { _ = linksOpened.insert(id) }
    Task {
      try? await pause(3)
      guard linksOpened.contains(id) else { return }
      finish(id, record: "Signed in")
    }
  }

  /// `reason` is what you typed or said instead of answering; the agent gets it as the next message.
  func deny(_ id: Int, reason: String? = nil) {
    guard approvalOrder.contains(id) else { return }
    afterApproval[id] = nil
    animate(Tokens.close) {
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
    guard let front = frontApproval, let approval = pendingApproval(front) else { return }
    switch approval.kind {
    case .questions:
      if allow { if canSubmit(front) { submitQuestions(front) } } else { skip(front) }
    case .form:
      if allow { submitForm(front) } else { deny(front) }
    case .link:
      if allow { openLink(front) } else { deny(front) }
    case .browser, .app:
      allow ? approve(front, grant: primaryGrant(approval)) : deny(front)
    case .command, .edit, .fetch:
      allow ? approve(front) : deny(front)
    }
  }

  /// What the Allow button gives. Browser and Computer Use ask again on every action unless the
  /// answer lasts, so the lab can put the lasting grant first.
  func primaryGrant(_ approval: Approval) -> Grant {
    switch approval.kind {
    case .browser, .app: lastingFirst == .lasting ? approval.grants[1] : .once
    default: .once
    }
  }

  /// ⌥1–⌥9 from any app pick an option on the question card on screen, never a hidden one.
  func pickFromKeyboard(_ number: Int) -> Bool {
    guard optionKeys == .option, openLevel == .idle, showsCard, let front = frontApproval,
      let questions = pendingApproval(front)?.questions, !questions.isEmpty
    else { return false }
    let question = currentQuestion(front)
    guard questions[question].options.indices.contains(number - 1) else { return false }
    pick(front, question: question, option: number - 1)
    return true
  }

  private func settle(_ id: Int) {
    questionStep[id] = nil
    picks[id] = nil
    ownWords[id] = nil
    formValues[id] = nil
    linksOpened.remove(id)
    approvalOrder.removeAll { $0 == id }
    collapsedCards.remove(id)
    cardIndex = min(cardIndex, max(cardThreads.count - 1, 0))
    if approvalOrder.isEmpty { keyRevealed = false }
  }

  /// A peek line always shrinks back; a card does only when the lab says so.
  private func scheduleCollapse(_ id: Int) {
    let lingers = pendingApproval(id)?.isQuestion == true && questionLinger == .untilAnswered
    let seconds: Double? = arrival == .peek ? 4 : cardLinger == .shrinks && !lingers ? 8 : nil
    guard let seconds, arrival != .mark else { return }
    Task {
      try? await pause(seconds)
      guard approvalOrder.contains(id), !keyRevealed else { return }
      animate(Tokens.close) { collapsedCards.insert(id) }
    }
  }

  func sendReply() {
    guard let id = openThread ?? selectedThread, !reply.isEmpty else { return }
    let text = reply
    reply = ""
    if approvalOrder.contains(id) {
      if pendingApproval(id)?.isQuestion == true { answerByText(id, text) } else { deny(id, reason: text) }
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
    case threeApprovals = "Three approvals"
    case longCommand = "Long command"
    case riskyTail = "Risky tail"
    case question = "Question"
    case questions = "Three questions"
    case browser = "Browser site"
    case app = "Computer Use app"
    case form = "MCP form"
    case link = "MCP sign-in"
    case mixed = "Question, site, command"
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
      case .question:
        start(1, Lab.questionTurn)
      case .questions:
        start(2, Lab.questionsTurn)
      case .browser:
        start(3, Lab.browserTurn)
      case .app:
        start(2, Lab.appTurn)
      case .form:
        start(1, Lab.formTurn)
      case .link:
        start(2, Lab.linkTurn)
      case .mixed:
        start(1, Lab.questionTurn)
        try? await pause(0.6)
        guard !Task.isCancelled else { return }
        start(3, Lab.browserTurn)
        try? await pause(0.6)
        guard !Task.isCancelled else { return }
        start(2, Lab.appcastTurn)
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
    questionStep = [:]
    picks = [:]
    ownWords = [:]
    formValues = [:]
    linksOpened = []
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

  static let approval = Approval(
    title: "Run a command?", command: "swift test --filter Overlay",
    reason: "Check the notch height fix against the overlay tests", detail: "~/dev/openvocally")

  /// What the lab pretends you said while a question waited.
  static let spokenAnswer = "Keep both for one release, then drop the old one."

  /// What the thread shows as done once a request is answered.
  static func stepAfter(_ approval: Approval) -> [String] {
    switch approval.kind {
    case .command: ["Ran \(approval.command)"]
    case .edit: ["Edited \(approval.command)"]
    case .fetch: ["Fetched \(approval.command)"]
    case .questions: ["Edited ShortcutSettings.swift"]
    case .browser(let site): ["Clicked Sign in on \(site)"]
    case .app(let name): ["Used \(name)"]
    case .form(let server, _): ["Called \(server)"]
    case .link(let server): ["Connected to \(server)"]
    }
  }

  static let questionTurn = Turn(
    prompt: "Change the agent toggle to ⌥F.",
    steps: ["Read ShortcutSettings.swift"],
    approval: Approval(
      kind: .questions([
        Question(
          header: "Old shortcut",
          text: "People who set ⌥Space for the old toggle will lose it. What should happen to their setting?",
          options: [
            QuestionOption(label: "Move it to ⌥F", detail: "Rewrite the saved shortcut on first launch, with no notice."),
            QuestionOption(label: "Keep ⌥Space for them", detail: "Only new installs get ⌥F."),
            QuestionOption(label: "Ask on first launch", detail: "Show a one-time choice in Settings."),
          ])
      ]),
      title: "Claude asks", command: ""),
    reply: "Moved saved ⌥Space toggles to ⌥F on first launch. New installs start with ⌥F.",
    end: .done("Answered"))

  static let questionsTurn = Turn(
    prompt: "Set up the 1.1 release.",
    steps: ["Read CHANGELOG.md", "Read project.yml"],
    approval: Approval(
      kind: .questions([
        Question(
          header: "Version",
          text: "Which version number should this release use?",
          options: [
            QuestionOption(label: "1.1.0", detail: "Agents is a new feature, so a minor bump."),
            QuestionOption(label: "1.0.5", detail: "Ship agents behind the flag in a patch."),
          ]),
        Question(
          header: "Channels",
          text: "Which update channels should get it?",
          options: [
            QuestionOption(label: "Stable", detail: "Everyone on the default feed."),
            QuestionOption(label: "Beta", detail: "People who opted into early builds."),
            QuestionOption(label: "Homebrew", detail: "Update the cask after the feed."),
          ],
          multiSelect: true),
        Question(
          header: "Notes",
          text: "Write the release notes from the merged pull requests, or draft them from the changelog?",
          options: [
            QuestionOption(label: "Merged pull requests", detail: nil),
            QuestionOption(label: "Changelog", detail: nil),
          ]),
      ]),
      title: "Codex asks", command: ""),
    reply: "Set 1.1.0, prepared the stable and beta feeds, and drafted the notes.", end: .done("Release prepared"))

  static let browserTurn = Turn(
    prompt: "Check the sign-in page on the local site.",
    steps: ["Opened a tab in Chrome"],
    approval: Approval(
      kind: .browser(site: "localhost:47812"), title: "Use Chrome on localhost:47812?",
      command: """
        navigate   http://localhost:47812/login
        find       "Sign in" button
        click      Sign in
        read_page
        """,
      reason: "Check that the sign-in button works", detail: "Claude in Chrome"),
    reply: "The button signs you in and lands on the dashboard. No console errors.", end: .done("Checked"))

  static let appTurn = Turn(
    prompt: "Work out 2 + 3 in Calculator.",
    steps: ["Listed open apps"],
    approval: Approval(
      kind: .app(name: "Calculator"), title: "Allow Computer Use to use \u{201C}Calculator\u{201D}?",
      command: "App     Calculator\nAction  click", reason: nil, detail: "Computer Use · low risk"),
    reply: "Calculator shows 5.", end: .done("5"))

  static let formTurn = Turn(
    prompt: "File the clipped first word as a Linear issue.",
    steps: ["Searched Linear for duplicates"],
    approval: Approval(
      kind: .form(
        server: "linear",
        fields: [
          FormField(label: "Team", kind: .choice(["Development", "Design", "Support"]), required: true),
          FormField(label: "Priority", kind: .choice(["Urgent", "High", "Medium", "Low"])),
          FormField(label: "Title", kind: .text(placeholder: "Clipped first word on Bluetooth headsets"), required: true),
          FormField(label: "Assign to me", kind: .toggle),
        ]),
      title: "linear needs a few details to create the issue", command: "", reason: nil, detail: "MCP server linear"),
    reply: "Filed the issue in Development.", end: .done("Issue filed"))

  static let linkTurn = Turn(
    prompt: "List my open Sentry issues.",
    steps: ["Connected to sentry"],
    approval: Approval(
      kind: .link(server: "sentry"), title: "Sign in to Sentry to continue",
      command: "https://sentry.io/oauth/authorize/?client_id=codex&state=4f2c9a", reason: nil,
      detail: "MCP server sentry"),
    reply: "You have 3 open issues. The newest is a crash in the model download.", end: .done("Answered"))

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
