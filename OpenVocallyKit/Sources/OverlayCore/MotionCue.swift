/// How the notch moves from one scene to the next.
package enum MotionCue: CaseIterable, Sendable, Equatable {
  case grow, shrink, keyboard, content

  /// A key press answers at keyboard speed whichever way the notch resizes; other causes grow or
  /// shrink with the footprint.
  package static func choose(from old: Footprint, to new: Footprint, cause: Cause) -> MotionCue {
    if old == new { return .content }
    if cause == .key { return .keyboard }
    return new > old ? .grow : .shrink
  }
}
