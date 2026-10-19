import DictationCore
import Testing

@testable import Hotkeys

private let t0 = HostTime(ticks: 1_000_000_000)

private func at(_ ms: Int) -> HostTime {
  t0.advanced(by: .milliseconds(ms))
}

private let option: Modifiers = [.option]

private enum Step {
  case flags(Modifiers, Int)
  case key(Modifiers)
  case reset
}

/// Returns what each step fired, `nil` for steps that are not flag changes.
private func run(_ steps: [Step], on detector: inout DoubleTapDetector) -> [ModifierKey?] {
  steps.map { step in
    switch step {
    case .flags(let modifiers, let ms):
      return detector.modifiersChanged(modifiers, at: at(ms))
    case .key(let modifiers):
      detector.keyEvent(holding: modifiers)
      return nil
    case .reset:
      detector.reset()
      return nil
    }
  }
}

private func run(_ steps: [Step]) -> [ModifierKey?] {
  var detector = DoubleTapDetector()
  return run(steps, on: &detector)
}

private let window = Int(DoubleTapDetector.window / .milliseconds(1))
private let tapMaxHold = Int(DoubleTapDetector.tapMaxHold / .milliseconds(1))

struct DoubleTapDetectorTests {
  @Test func `a clean double tap fires on the second release, not the second press`() {
    let fired = run([.flags(option, 0), .flags([], 80), .flags(option, 200), .flags([], 260)])
    #expect(fired == [nil, nil, nil, .option])
  }

  @Test func `a tap then option with a key inside the window does not fire`() {
    let fired = run([
      .flags(option, 0), .flags([], 50),
      .flags(option, 100), .key(option), .key(option), .flags([], 180),
    ])
    #expect(fired.allSatisfy { $0 == nil })
  }

  @Test func `a second press held longer than a tap does not fire`() {
    let fired = run([
      .flags(option, 0), .flags([], 50),
      .flags(option, 100), .flags([], 100 + tapMaxHold + 1),
    ])
    #expect(fired.allSatisfy { $0 == nil })
  }

  @Test(arguments: [(0, true), (1, false)])
  func `the gap fires at exactly the window and not just over`(over: Int, fires: Bool) {
    let second = 50 + window + over
    let fired = run([
      .flags(option, 0), .flags([], 50),
      .flags(option, second), .flags([], second + 50),
    ])
    #expect(fired == [nil, nil, nil, fires ? .option : nil])
  }

  @Test func `left then right option still counts`() {
    let fired = run([
      .flags(option, 0), .flags(option, 20), .flags([], 50), .flags([], 60),
      .flags(option, 100), .flags([], 150),
    ])
    #expect(fired.last == .option)
  }

  @Test func `reset mid gesture drops it`() {
    let fired = run([.flags(option, 0), .flags([], 50), .flags(option, 100), .reset, .flags([], 150)])
    #expect(fired.allSatisfy { $0 == nil })
  }

  @Test func `a key event's modifiers heal a lost release`() {
    var detector = DoubleTapDetector()
    _ = run([.flags(option, 0)], on: &detector)
    // The release was lost; the next key event carries no modifiers.
    _ = run([.key([])], on: &detector)
    let fired = run(
      [.flags(option, 1000), .flags([], 1050), .flags(option, 1100), .flags([], 1150)],
      on: &detector)
    #expect(fired.last == .option)
  }
}
