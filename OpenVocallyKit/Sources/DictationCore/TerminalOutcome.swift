enum TerminalOutcome: Sendable, Equatable {
  case complete
  case failed(DictationFailureReason, hasMessage: Bool)

  var displayDuration: Duration {
    switch self {
    case .complete: .milliseconds(650)
    case .failed(.aborted, _): .milliseconds(120)
    case .failed(_, hasMessage: true): .milliseconds(2900)
    case .failed(_, hasMessage: false): .milliseconds(1900)
    }
  }

  static let pasteLastErrorDisplayDuration: Duration = .milliseconds(1100)
}
