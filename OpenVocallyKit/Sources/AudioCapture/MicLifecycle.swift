struct MicLifecycle: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case closed
    case recording
    case warm(until: ContinuousClock.Instant)
  }

  enum Action: Equatable, Sendable {
    case none
    case stopMic
    case keepWarm(until: ContinuousClock.Instant)
  }

  private(set) var state: State = .closed

  var isRecording: Bool {
    state == .recording
  }

  mutating func start() {
    state = .recording
  }

  mutating func stop(now: ContinuousClock.Instant, warm warmDuration: Duration) -> Action {
    guard state == .recording else { return .none }
    guard warmDuration > .zero else {
      state = .closed
      return .stopMic
    }
    let until = now.advanced(by: warmDuration)
    state = .warm(until: until)
    return .keepWarm(until: until)
  }

  mutating func warmExpired(now: ContinuousClock.Instant) -> Action {
    guard case .warm(let until) = state, now >= until else { return .none }
    state = .closed
    return .stopMic
  }

  mutating func release() -> Action {
    guard state != .closed else { return .none }
    state = .closed
    return .stopMic
  }
}
