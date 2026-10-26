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

  /// The display under the pointer, whether or not the notch may show there.
  package var pointerDisplay: DisplayID? { inputs.pointerDisplay }

  /// The display under the pointer when it has a menu bar, where the notch shows.
  package var activeDisplay: DisplayID? {
    guard let display = inputs.pointerDisplay, inputs.menuBarDisplays.contains(display) else {
      return nil
    }
    return display
  }

  /// When the next `.tick` is due, or nil when nothing waits on time.
  package var nextDeadline: HostTime? { inputs.connectingDeadline }

  /// Applies `event` and returns the frames to show.
  ///
  /// Send a `.displays` and a `.pointer` event before anything can show: until the pointer is on a
  /// display with a menu bar, events update the state but show nothing.
  package mutating func send(_ event: NotchEvent, at now: HostTime) -> NotchOutcome {
    let oldDisplay = activeDisplay
    inputs.apply(event, at: now)
    let scene = inputs.scene
    let display = activeDisplay

    if let display, display == oldDisplay {
      guard scene != committed else { return NotchOutcome(frames: [:]) }
      let motion = MotionCue.choose(
        from: committed.footprint, to: scene.footprint, cause: event.cause)
      committed = scene
      return NotchOutcome(frames: [display: NotchFrame(scene: scene, motion: motion)])
    }

    var frames: [DisplayID: NotchFrame] = [:]
    if let oldDisplay, committed != .hidden {
      frames[oldDisplay] = NotchFrame(
        scene: .hidden,
        motion: .choose(from: committed.footprint, to: .hidden, cause: event.cause))
    }
    if let display, scene != .hidden {
      frames[display] = NotchFrame(
        scene: scene, motion: .choose(from: .hidden, to: scene.footprint, cause: event.cause))
    }
    committed = display == nil ? .hidden : scene
    return NotchOutcome(frames: frames)
  }
}
