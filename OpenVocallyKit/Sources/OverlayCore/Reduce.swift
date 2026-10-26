import DictationCore

extension NotchInputs {
  mutating func apply(_ event: NotchEvent, at now: HostTime) {
    switch event {
    case .dictation(let phase): apply(phase, at: now)
    case .pointer(let display): pointerDisplay = display
    case .displays(let displays): menuBarDisplays = displays
    case .tick:
      if let dictation, dictation.voice == .starting, let deadline = connectingDeadline,
        now >= deadline
      {
        self.dictation = DictationInput(voice: .connecting, startedAt: dictation.startedAt)
      }
    }
  }

  var connectingDeadline: HostTime? {
    guard let dictation, dictation.voice == .starting, let startedAt = dictation.startedAt else {
      return nil
    }
    return startedAt.advanced(by: NotchCore.connectingDelay)
  }

  var scene: NotchScene {
    if let dictation { return NotchScene(strip: .voice(dictation.voice)) }
    if let notice { return NotchScene(strip: .notice(notice)) }
    if let flash { return NotchScene(strip: .flash(flash)) }
    return .hidden
  }

  private mutating func apply(_ phase: DictationPhase, at now: HostTime) {
    switch phase {
    case .idle, .failed(.aborted):
      dictation = nil
      notice = nil
      flash = nil
    case .starting:
      if let dictation, dictation.voice == .starting || dictation.voice == .connecting { return }
      dictation = DictationInput(voice: .starting, startedAt: now)
      notice = nil
      flash = nil
    case .recording: dictation = DictationInput(voice: .recording)
    case .stopping, .transcribing: dictation = DictationInput(voice: .transcribing)
    case .pasting: dictation = DictationInput(voice: .pasting)
    case .complete:
      dictation = nil
      notice = nil
      flash = .pasted
    case .failed(let reason):
      dictation = nil
      notice = .failure(reason)
    case .awaitingManualPaste(let until):
      dictation = nil
      notice = .manualPaste(until: until)
    }
  }
}
