import DictationCore
import Testing

@testable import Hotkeys

private let rightCommand = HeldKeys(.rightCommand)
private let leftCommand = HeldKeys(.leftCommand)
private let bothCommands = HeldKeys([HeldKeys(.leftCommand), HeldKeys(.rightCommand)])
private let c = KeyCode(rawValue: 8)
private let k = KeyCode(rawValue: 40)
private let a = KeyCode(rawValue: 0)

private let start = Verdict(.pass, emit: .holdStart(trial: false))
private let abort = Verdict(.pass, emit: .holdAbort)
private let stop = Verdict(.pass, emit: .pushToTalkStop)

private func at(_ ms: UInt64) -> HostTime { HostTime(nanoseconds: ms * 1_000_000) }

/// The one-key push to talk drop rule. Every verdict passes the event on.
struct HoldMatcherTests {
  private func bound(_ key: HoldKey = .rightCommand) throws -> HotkeyMatcher {
    HotkeyMatcher(bindings: try HotkeyBindings.chordFixture.replacing(.pushToTalk, with: .hold(key)))
  }

  private func feed(_ m: inout HotkeyMatcher, _ events: [(KeyEvent, UInt64)]) -> [Verdict] {
    events.map { m.handle($0.0, at: at($0.1)) }
  }

  @Test func `hold starts on key-down and stops on release`() throws {
    var m = try bound()
    #expect(feed(&m, [(.modifiersChanged(rightCommand), 0), (.modifiersChanged([]), 900)]) == [start, stop])
  }

  @Test func `another key drops the hold and passes`() throws {
    var m = try bound()
    let verdicts = feed(
      &m,
      [
        (.modifiersChanged(rightCommand), 0), (.down(c, [.command]), 80), (.up(c, [.command]), 120),
        (.modifiersChanged([]), 200),
      ])
    #expect(verdicts == [start, abort, .pass, .pass])
  }

  @Test func `another key after the confirm window still drops`() throws {
    var m = try bound()
    let verdicts = feed(
      &m, [(.modifiersChanged(rightCommand), 0), (.down(c, [.command]), 2000), (.modifiersChanged([]), 2100)])
    #expect(verdicts == [start, abort, .pass])
  }

  @Test func `releasing the other key does not restart`() throws {
    var m = try bound()
    let verdicts = feed(
      &m,
      [
        (.modifiersChanged(rightCommand), 0), (.modifiersChanged(bothCommands), 50),
        (.modifiersChanged(rightCommand), 100), (.modifiersChanged([]), 300),
      ])
    #expect(verdicts == [start, abort, .pass, .pass])
  }

  @Test func `spent hold does not restart after releasing C`() throws {
    var m = try bound()
    let verdicts = feed(
      &m,
      [
        (.modifiersChanged(rightCommand), 0), (.down(c, [.command]), 80), (.up(c, [.command]), 120),
        (.modifiersChanged(rightCommand), 150), (.modifiersChanged([]), 400),
        (.modifiersChanged(rightCommand), 500),
      ])
    #expect(verdicts == [start, abort, .pass, .pass, .pass, start])
  }

  @Test func `a second modifier drops`() throws {
    var m = try bound()
    let verdicts = feed(
      &m,
      [
        (.modifiersChanged(rightCommand), 0),
        (.modifiersChanged(HeldKeys([rightCommand, HeldKeys(.leftShift)])), 60),
      ])
    #expect(verdicts == [start, abort])
  }

  @Test func `a click drops`() throws {
    var m = try bound()
    let verdicts = feed(
      &m, [(.modifiersChanged(rightCommand), 0), (.pointerDown, 70), (.modifiersChanged([]), 200)])
    #expect(verdicts == [start, abort, .pass])
  }

  @Test func `left command does not trigger a right command binding`() throws {
    var m = try bound()
    #expect(feed(&m, [(.modifiersChanged(leftCommand), 0), (.modifiersChanged([]), 900)]) == [.pass, .pass])
  }

  @Test func `right after left held is not alone`() throws {
    var m = try bound()
    let verdicts = feed(
      &m,
      [
        (.modifiersChanged(leftCommand), 0), (.modifiersChanged(bothCommands), 50),
        (.modifiersChanged(leftCommand), 600), (.modifiersChanged([]), 700),
      ])
    #expect(verdicts == [.pass, .pass, .pass, .pass])
  }

  @Test func `releasing left while right stays down does not start`() throws {
    var m = try bound()
    #expect(
      feed(&m, [(.modifiersChanged(bothCommands), 0), (.modifiersChanged(rightCommand), 50)]) == [
        .pass, .pass,
      ])
  }

  @Test func `fn hold`() throws {
    var m = try bound(.fn)
    #expect(
      feed(&m, [(.modifiersChanged(HeldKeys(.fn)), 0), (.modifiersChanged([]), 800)]) == [start, stop])
  }

  @Test func `a key down before the press blocks nothing, its key-up aborts`() throws {
    var m = try bound()
    let verdicts = feed(&m, [(.down(a, []), 0), (.modifiersChanged(rightCommand), 10), (.up(a, []), 40)])
    #expect(verdicts == [.pass, start, abort])
  }

  @Test func `abort and a bound chord in one verdict`() throws {
    let bindings = try HotkeyBindings.chordFixture
      .replacing(.pushToTalk, with: .hold(.rightCommand))
      .replacing(.toggle, with: .chord(KeyChord(k, [.command])))
    var m = HotkeyMatcher(bindings: bindings)
    let verdicts = feed(&m, [(.modifiersChanged(rightCommand), 0), (.down(k, [.command]), 90)])
    #expect(verdicts == [start, Verdict(.consume, emits: [.holdAbort, .toggle])])
  }

  @Test func `autorepeat during the hold aborts`() throws {
    var m = try bound()
    let verdicts = feed(
      &m, [(.modifiersChanged(rightCommand), 0), (.down(a, [.command], isAutorepeat: true), 50)])
    #expect(verdicts == [start, abort])
  }

  @Test func `a quick tap starts then stops`() throws {
    var m = try bound()
    #expect(feed(&m, [(.modifiersChanged(rightCommand), 0), (.modifiersChanged([]), 60)]) == [start, stop])
  }

  @Test func `recording mode ignores the hold`() throws {
    var m = try bound()
    #expect(m.setMode(.recording) == nil)
    #expect(
      feed(&m, [(.modifiersChanged(rightCommand), 0), (.modifiersChanged([]), 500)]) == [.pass, .pass])
  }

  @Test func `trial mode arms the trial key`() throws {
    var m = try bound()
    #expect(m.setMode(.trial(.rightOption)) == nil)
    let verdicts = feed(&m, [(.modifiersChanged(HeldKeys(.rightOption)), 0), (.modifiersChanged([]), 700)])
    #expect(verdicts == [Verdict(.pass, emit: .holdStart(trial: true)), stop])
  }

  @Test func `trial mode ignores the stored binding`() throws {
    var m = try bound()
    _ = m.setMode(.trial(.rightOption))
    #expect(m.handle(.modifiersChanged(rightCommand), at: at(0)) == .pass)
  }

  @Test func `leaving trial aborts a live trial hold`() throws {
    var m = try bound()
    _ = m.setMode(.trial(.rightOption))
    _ = m.handle(.modifiersChanged(HeldKeys(.rightOption)), at: at(0))
    #expect(m.setMode(.recording) == .holdAbort)
    #expect(m.handle(.modifiersChanged([]), at: at(100)) == .pass)
  }

  @Test func `a tap reset aborts a one-key hold`() throws {
    var m = try bound()
    _ = m.handle(.modifiersChanged(rightCommand), at: at(0))
    #expect(m.tapWasReset() == .holdAbort)
    #expect(m.handle(.modifiersChanged([]), at: at(100)) == .pass)
  }

  @Test func `a tap reset after a lost release does not eat the next hold`() throws {
    var m = try bound()
    _ = feed(
      &m, [(.modifiersChanged(rightCommand), 0), (.down(c, [.command]), 80), (.up(c, [.command]), 120)])
    #expect(m.tapWasReset() == nil)
    let next = feed(&m, [(.modifiersChanged(rightCommand), 5000), (.modifiersChanged([]), 6000)])
    #expect(next == [start, stop])
  }

  @Test func `a tap reset still stops a chord hold`() {
    var m = HotkeyMatcher(bindings: .chordFixture)
    _ = m.handle(.down(.l, [.command, .shift]), at: at(0))
    #expect(m.tapWasReset() == .pushToTalkStop)
  }

  @Test func `a rebind aborts a one-key hold`() throws {
    var m = try bound()
    _ = m.handle(.modifiersChanged(rightCommand), at: at(0))
    #expect(m.rebind(.chordFixture) == .holdAbort)
  }

  @Test func `double tap still works for another family`() throws {
    let bindings = try HotkeyBindings.chordFixture
      .replacing(.pushToTalk, with: .hold(.rightCommand))
      .replacing(.toggle, with: .doubleTap(.option))
    var m = HotkeyMatcher(bindings: bindings)
    let option = HeldKeys(.leftOption)
    let verdicts = feed(
      &m,
      [
        (.modifiersChanged(option), 0), (.modifiersChanged([]), 80), (.modifiersChanged(option), 200),
        (.modifiersChanged([]), 260),
      ])
    #expect(verdicts.last == Verdict(.pass, emit: .toggle))
  }
}
