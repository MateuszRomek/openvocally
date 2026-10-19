/// When a screen was created and whether it has reported its open signpost yet. A class, so
/// recording the report does not redraw the screen.
final class ScreenOpenReport {
  let openedAt = ContinuousClock.now
  private(set) var isReported = false

  var sinceOpened: Duration { .now - openedAt }

  /// True the first time only, so each screen reports its open once.
  func markReported() -> Bool {
    guard !isReported else { return false }
    isReported = true
    return true
  }
}
