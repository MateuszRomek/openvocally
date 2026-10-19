public enum CaptureFailure: Sendable, Equatable {
  case noInputDevice
  case startTimedOut
  case stopTimedOut
  case deviceLost
  case captureFailed
}
