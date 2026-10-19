/// What Try it heard, for the setup card.
public enum TrialResult: Sendable, Equatable {
  case heard(Transcript)
  case failed(DictationFailureReason)
}

/// The dictation state machine, as a value. `handle` is a pure transition.
///
/// A completion for any session other than the current one, or for a stage the session has
/// already left, returns no effects and changes nothing. That one rule settles every race
/// between user commands and slow work.
public struct DictationMachine: Sendable {
  enum Stage: Sendable, Equatable {
    case starting, recording, stopping, transcribing, processing, pasting
    case awaitingManualPaste(until: HostTime)
  }

  /// How long the user has to press ⌘V after a failed auto-paste.
  public static let manualPasteWindow: Duration = .seconds(10)

  struct Session: Sendable, Equatable {
    let id: SessionID
    let mode: RecordingMode
    let pressedAt: HostTime
    var releasedAt: HostTime?
    var stage: Stage
    var transcript: Transcript?
    /// Set for a session started by holding one key alone.
    var hold: Hold?

    var isTrial: Bool { hold?.isTrial == true }
    /// A ⌘ shortcut must never beep, so a one-key hold plays its start cue only once confirmed.
    var defersStartCue: Bool { hold?.isConfirmed == false }
  }

  enum State: Sendable, Equatable {
    case idle
    case active(Session)
    case terminal(SessionRecord)
    /// Not a dictation session: no recording mode, no `SessionRecord`. Shows the Pasting
    /// pill while it runs and hides on success without the Pasted flash.
    case pastingLast(SessionID)
    case pasteLastFailed(SessionID, DictationFailureReason)
  }

  private var state: State = .idle
  private var lastID: UInt64 = 0
  /// Set before the dictation's own paste, so text whose paste failed can still be re-pasted.
  private var lastTranscript: Transcript?

  public init() {}

  public var phase: DictationPhase {
    switch state {
    case .idle: .idle
    case .active(let session):
      switch session.stage {
      case .starting: .starting(session.mode)
      case .recording: .recording(session.mode)
      case .stopping: .stopping
      case .transcribing, .processing: .transcribing
      case .pasting: .pasting
      case .awaitingManualPaste(let until): .awaitingManualPaste(until: until)
      }
    case .terminal(let record):
      switch record.outcome {
      case .complete: .complete
      case .failed(let reason, _): .failed(reason)
      }
    case .pastingLast: .pasting
    case .pasteLastFailed(_, let reason): .failed(reason)
    }
  }

  public var currentSession: SessionID? {
    switch state {
    case .idle: nil
    case .active(let session): session.id
    case .terminal(let record): record.id
    case .pastingLast(let id), .pasteLastFailed(let id, _): id
    }
  }

  public var pressedAt: HostTime? {
    switch state {
    case .idle: nil
    case .active(let session): session.pressedAt
    case .terminal(let record): record.pressedAt
    case .pastingLast, .pasteLastFailed: nil
    }
  }

  /// The pending or confirmed one-key hold of the current session, through its terminal
  /// display. nil for a chord, toggle or menu session.
  public var hold: Hold? {
    switch state {
    case .active(let session): session.hold
    case .terminal(let record): record.hold
    case .idle, .pastingLast, .pasteLastFailed: nil
    }
  }

  /// Set while a finished trial session's terminal display lasts.
  public var trialResult: TrialResult? {
    guard case .terminal(let record) = state, record.hold?.isTrial == true else { return nil }
    switch record.outcome {
    case .complete: return record.trialTranscript.map(TrialResult.heard)
    case .failed(let reason, _): return .failed(reason)
    }
  }

  /// Set while the complete or failed display shows.
  var finishedSession: SessionRecord? {
    if case .terminal(let record) = state { record } else { nil }
  }

  public mutating func handle(_ event: DictationEvent) -> [DictationEffect] {
    switch event {
    case .command(let command, let at):
      return handle(command, at: at)
    case .captureStarted(let id):
      guard var session = active(id, in: .starting) else { return [] }
      session.stage = .recording
      state = .active(session)
      return session.defersStartCue ? [] : [.playCue(.start)]
    case .holdConfirmed(let id):
      guard case .active(var session) = state, session.id == id, var hold = session.hold, !hold.isConfirmed,
        session.stage == .starting || session.stage == .recording
      else { return [] }
      hold.isConfirmed = true
      session.hold = hold
      state = .active(session)
      return session.stage == .recording ? [.playCue(.start)] : []
    case .captureStopped(let id, let samples):
      guard var session = active(id, in: .stopping) else { return [] }
      session.stage = .transcribing
      state = .active(session)
      if session.isTrial { return [.transcribe(id, samples: samples)] }
      return [.keepRecording(id, samples: samples), .transcribe(id, samples: samples)]
    case .transcribed(let id, let transcript):
      guard var session = active(id, in: .transcribing) else { return [] }
      session.stage = .processing
      state = .active(session)
      if session.isTrial { return [.process(id, transcript)] }
      return [.discardRecording(id), .process(id, transcript)]
    case .processed(let id, let transcript):
      guard var session = active(id, in: .processing) else { return [] }
      if session.isTrial {
        return finish(session, .complete, target: nil, trialTranscript: transcript)
      }
      session.stage = .pasting
      session.transcript = transcript
      state = .active(session)
      lastTranscript = transcript
      return [.paste(id, transcript)]
    case .pasted(let id, let target, let at):
      if case .pastingLast(id) = state {
        state = .idle
        return []
      }
      if let session = awaitingManualPaste(id) {
        return finish(session, .complete, target: target)
      }
      guard let session = active(id, in: .pasting) else { return [] }
      var effects = finish(session, .complete, target: target)
      if let released = session.releasedAt {
        effects.insert(.latency(.releaseToPasted(at.duration(since: released))), at: 0)
      }
      return effects
    case .manualPasteNeeded(let id, let at):
      guard var session = active(id, in: .pasting) else { return [] }
      session.stage = .awaitingManualPaste(until: at.advanced(by: Self.manualPasteWindow))
      state = .active(session)
      return [.expireManualPaste(id, after: Self.manualPasteWindow)]
    case .manualPasteExpired(let id):
      guard let session = awaitingManualPaste(id) else { return [] }
      return [.abandonManualPaste(id)]
        + finish(session, .failed(.manualPasteExpired, hasMessage: true), target: nil)
    case .failed(let id, let reason):
      if case .pastingLast(id) = state {
        return failPasteLast(id, reason)
      }
      guard case .active(let session) = state, session.id == id else { return [] }
      return finish(session, .failed(reason, hasMessage: reason != .aborted), target: nil)
    case .terminalDisplayEnded(let id):
      switch state {
      case .terminal(let record) where record.id == id: state = .idle
      case .pasteLastFailed(id, _): state = .idle
      default: break
      }
      return []
    }
  }

  private mutating func handle(_ command: DictationCommand, at: HostTime) -> [DictationEffect] {
    switch phase.intent(for: command) {
    case .pasteLast:
      let closing = closeManualPasteWindow()
      let id = nextID()
      guard let lastTranscript else { return closing + failPasteLast(id, .nothingToPaste) }
      state = .pastingLast(id)
      return closing + [.pasteLast(id, lastTranscript)]
    case .ignore:
      return []
    case .manualPaste:
      guard case .active(let session) = state else { return [] }
      return [.completeManualPaste(session.id)]
    case .cancelManualPaste:
      guard case .active(let session) = state else { return [] }
      return [.abandonManualPaste(session.id), .playCue(.cancel)]
        + finish(session, .failed(.aborted, hasMessage: false), target: nil)
    case .start(let mode, let hold):
      let closing = closeManualPasteWindow()
      let id = nextID()
      state = .active(Session(id: id, mode: mode, pressedAt: at, stage: .starting, hold: hold))
      let confirm: [DictationEffect] =
        hold == nil ? [] : [.confirmHold(id, at: at.advanced(by: Hold.confirmDelay))]
      return closing + [.startCapture(id, pressedAt: at)] + confirm
    case .discard:
      return discardHold()
    case .stop:
      if isStrayHold { return discardHold() }
      guard case .active(var session) = state, session.stage == .recording else { return [] }
      session.stage = .stopping
      session.releasedAt = at
      state = .active(session)
      return [.stopCapture(session.id, releasedAt: at)]
    case .cancel:
      if isStrayHold { return discardHold() }
      guard case .active(let session) = state else { return [] }
      return [.cancelCapture(session.id), .playCue(.cancel)]
        + finish(session, .failed(.aborted, hasMessage: false), target: nil)
    case .cancelTranscription:
      // The transcription keeps running; its result meets a stale session id and is dropped.
      guard case .active(let session) = state else { return [] }
      return [.playCue(.cancel)] + finish(session, .failed(.aborted, hasMessage: false), target: nil)
    }
  }

  /// A one-key hold that ends before `Hold.confirmDelay` is a stray press, not a session.
  private var isStrayHold: Bool {
    guard case .active(let session) = state, session.stage == .starting || session.stage == .recording
    else { return false }
    return session.hold?.isConfirmed == false
  }

  /// Ends a one-key hold with no cue, record, save, terminal display or paste.
  private mutating func discardHold() -> [DictationEffect] {
    guard case .active(let session) = state, session.hold != nil,
      session.stage == .starting || session.stage == .recording
    else { return [] }
    state = .idle
    return [.cancelCapture(session.id)]
  }

  private mutating func nextID() -> SessionID {
    lastID += 1
    return SessionID(raw: lastID)
  }

  private mutating func failPasteLast(_ id: SessionID, _ reason: DictationFailureReason) -> [DictationEffect]
  {
    state = .pasteLastFailed(id, reason)
    return [.playCue(.error), .endTerminalDisplay(id, after: TerminalOutcome.pasteLastErrorDisplayDuration)]
  }

  /// A new press closes an open manual paste window instead of waiting it out. The transcript
  /// is saved, and the window ends without a cue or a message.
  private mutating func closeManualPasteWindow() -> [DictationEffect] {
    guard let currentSession, let session = awaitingManualPaste(currentSession) else { return [] }
    let saved = finish(session, .failed(.manualPasteExpired, hasMessage: false), target: nil).filter {
      if case .save = $0 { true } else { false }
    }
    return [.abandonManualPaste(session.id)] + saved
  }

  private func awaitingManualPaste(_ id: SessionID) -> Session? {
    guard case .active(let session) = state, session.id == id,
      case .awaitingManualPaste = session.stage
    else { return nil }
    return session
  }

  private func active(_ id: SessionID, in stage: Stage) -> Session? {
    guard case .active(let session) = state, session.id == id, session.stage == stage else { return nil }
    return session
  }

  private mutating func finish(
    _ session: Session, _ outcome: TerminalOutcome, target: TargetApp?, trialTranscript: Transcript? = nil
  ) -> [DictationEffect] {
    state = .terminal(
      SessionRecord(
        id: session.id, mode: session.mode, pressedAt: session.pressedAt, outcome: outcome, target: target,
        hold: session.hold, trialTranscript: trialTranscript))
    var effects: [DictationEffect] = []
    if session.isTrial {
      if case .failed(let reason, _) = outcome, reason.isError { effects.append(.playCue(.error)) }
      effects.append(.endTerminalDisplay(session.id, after: outcome.displayDuration))
      return effects
    }
    // A cancel is the user's choice, not an error, so its audio is not kept.
    if session.stage == .transcribing, case .failed(let reason, _) = outcome {
      effects.append(reason == .aborted ? .discardRecording(session.id) : .failRecording(session.id, reason))
    }
    if let transcript = session.transcript, let releasedAt = session.releasedAt {
      effects.append(
        .save(
          DictationEntry(
            session: session.id, mode: session.mode, pressedAt: session.pressedAt,
            recordingDuration: releasedAt.duration(since: session.pressedAt), transcript: transcript,
            target: target)))
    }
    if case .failed(let reason, _) = outcome, reason.isError { effects.append(.playCue(.error)) }
    effects.append(.endTerminalDisplay(session.id, after: outcome.displayDuration))
    return effects
  }
}
