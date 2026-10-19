import DictationCore
import Testing

@testable import Hotkeys

private func at(_ ms: UInt64) -> HostTime { HostTime(nanoseconds: ms * 1_000_000) }

struct ShortcutRecorderTests {
  private func feed(_ action: HotkeyAction, _ events: [(KeyEvent, UInt64)]) -> [ShortcutRecorder.Step] {
    var recorder = ShortcutRecorder(recording: action)
    return events.map { recorder.handle($0.0, at: at($0.1)) }
  }

  @Test func `live key caps`() {
    #expect(
      feed(.pushToTalk, [(.modifiersChanged(HeldKeys(.rightCommand)), 0)]) == [.held(HeldKeys(.rightCommand))]
    )
  }

  @Test func `a single key offers a hold`() {
    let steps = feed(
      .pushToTalk, [(.modifiersChanged(HeldKeys(.rightCommand)), 0), (.modifiersChanged([]), 700)])
    #expect(steps == [.held(HeldKeys(.rightCommand)), .offerHold(.rightCommand)])
  }

  @Test func `a chord saves at once and its release offers nothing`() {
    let steps = feed(
      .pushToTalk,
      [
        (.modifiersChanged(HeldKeys(.leftOption)), 0), (.down(.space, [.option]), 100),
        (.modifiersChanged([]), 300),
      ])
    #expect(steps == [.held(HeldKeys(.leftOption)), .save(.chord(KeyChord(.space, [.option]))), .held([])])
  }

  @Test func `two modifiers then release offers nothing`() {
    let both = HeldKeys([HeldKeys(.rightCommand), HeldKeys(.rightShift)])
    let steps = feed(
      .pushToTalk,
      [
        (.modifiersChanged(HeldKeys(.rightCommand)), 0), (.modifiersChanged(both), 50),
        (.modifiersChanged([]), 200),
      ])
    #expect(steps == [.held(HeldKeys(.rightCommand)), .held(both), .held([])])
  }

  @Test func `a double tap saves on another row`() {
    let option = HeldKeys(.leftOption)
    let steps = feed(
      .toggle,
      [
        (.modifiersChanged(option), 0), (.modifiersChanged([]), 80), (.modifiersChanged(option), 200),
        (.modifiersChanged([]), 260),
      ])
    #expect(steps.last == .save(.doubleTap(.option)))
  }

  @Test func `a single key on another row only redraws`() {
    let steps = feed(
      .toggle, [(.modifiersChanged(HeldKeys(.rightCommand)), 0), (.modifiersChanged([]), 500)])
    #expect(steps == [.held(HeldKeys(.rightCommand)), .held([])])
  }

  @Test func `escape stops`() {
    #expect(feed(.pushToTalk, [(.down(.escape, []), 0)]) == [.stop])
  }

  @Test func `an unlabeled key is unsupported`() {
    #expect(feed(.pushToTalk, [(.down(KeyCode(rawValue: 200), [.option]), 0)]) == [.unsupportedKey])
  }
}
