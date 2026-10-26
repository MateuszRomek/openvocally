import DictationCore
import OverlayCore
import Testing

struct RecordedFrame: Equatable, Sendable, CustomTestStringConvertible {
  let display: UInt32
  let footprint: Footprint
  let cue: MotionCue
  let strip: StripLead?

  var testDescription: String { "\(display) \(footprint) \(cue) \(String(describing: strip))" }
}

/// Plays the host: owns the clock and delivers every due tick before the next event.
struct NotchRig {
  private var core = NotchCore()
  private var now = HostTime(ticks: 1_000_000_000)
  private(set) var frames: [RecordedFrame] = []

  init() {
    deliver(.displays(withMenuBar: [DisplayID(rawValue: 1), DisplayID(rawValue: 2)]))
  }

  mutating func send(_ event: NotchEvent, after delay: Duration = .zero) {
    let target = now.advanced(by: delay)
    while let deadline = core.nextDeadline, deadline <= target {
      now = deadline
      deliver(.tick)
    }
    now = target
    deliver(event)
  }

  private mutating func deliver(_ event: NotchEvent) {
    let outcome = core.send(event, at: now)
    for (display, frame) in outcome.frames.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      frames.append(
        RecordedFrame(
          display: display.rawValue, footprint: frame.scene.footprint, cue: frame.motion,
          strip: frame.scene.strip))
    }
  }
}
