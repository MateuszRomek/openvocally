/// How the notch moves from one scene to the next.
package enum MotionCue: CaseIterable, Sendable, Equatable {
  case grow, shrink, keyboard, content, appear

  /// The notch appearing from hidden always gets a visible entry, even on a key press; otherwise a
  /// key press answers at keyboard speed whichever way the notch resizes, and other causes grow or
  /// shrink with the footprint.
  package static func choose(from old: Footprint, to new: Footprint, cause: Cause) -> MotionCue {
    if old == new { return .content }
    if old == .hidden { return .appear }
    if cause == .key { return .keyboard }
    return new > old ? .grow : .shrink
  }
}
