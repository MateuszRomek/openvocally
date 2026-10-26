import DictationCore

struct DictationInput: Sendable, Equatable {
  var voice: Voice
  /// Set while `voice` is `.starting` or `.connecting`, to time the connecting deadline.
  var startedAt: HostTime?
}

/// The notch's inputs, grouped by the source that changes them.
struct NotchInputs: Sendable, Equatable {
  var dictation: DictationInput?
  var notice: Notice?
  var flash: Flash?
  var pointerDisplay: DisplayID?
  var menuBarDisplays: Set<DisplayID> = []
}
