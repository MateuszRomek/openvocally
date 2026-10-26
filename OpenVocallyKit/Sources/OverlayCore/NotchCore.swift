import DictationCore

/// The dictation notch as a reducer: events in, frames for each display out.
package struct NotchCore: Sendable {
  /// How long `.starting` shows as recording before it admits the mic is still connecting.
  package static let connectingDelay: Duration = .milliseconds(300)

  var inputs = NotchInputs()
  /// The scene last shown on the active display, kept only to choose the next motion.
  private(set) var committed = NotchScene.hidden

  package init() {}

  package var scene: NotchScene { inputs.scene }

  /// The display under the pointer, where the notch shows.
  package var activeDisplay: DisplayID? { inputs.pointerDisplay }

  /// When the next `.tick` is due, or nil when nothing waits on time.
  package var nextDeadline: HostTime? { inputs.connectingDeadline }

  /// Applies `event` and returns the frames to show.
  ///
  /// Send a `.pointer` event before the first dictation event: until a display is known, events
  /// update the state but show nothing.
  package mutating func send(_ event: NotchEvent, at now: HostTime) -> NotchOutcome {
    let oldDisplay = inputs.pointerDisplay
    inputs.apply(event, at: now)
    let scene = inputs.scene
    guard let display = inputs.pointerDisplay else { return NotchOutcome(frames: [:]) }

    if let oldDisplay, oldDisplay != display {
      let old = committed
      committed = scene
      guard old != .hidden || scene != .hidden else { return NotchOutcome(frames: [:]) }
      return NotchOutcome(frames: [
        oldDisplay: NotchFrame(
          scene: .hidden,
          motion: .choose(from: old.footprint, to: .hidden, cause: event.cause)),
        display: NotchFrame(
          scene: scene,
          motion: .choose(from: .hidden, to: scene.footprint, cause: event.cause)),
      ])
    }

    guard scene != committed else { return NotchOutcome(frames: [:]) }
    let motion = MotionCue.choose(from: committed.footprint, to: scene.footprint, cause: event.cause)
    committed = scene
    return NotchOutcome(frames: [display: NotchFrame(scene: scene, motion: motion)])
  }
}
