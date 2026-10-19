import DictationCore
import Testing

@testable import Hotkeys

private let cmdShift: Modifiers = [.command, .shift]
private let consume = Verdict(.consume)
private let start = Verdict(.consume, emit: .pushToTalkStart)
private let stop = Verdict(.consume, emit: .pushToTalkStop)
private let cancel = Verdict(.consume, emit: .cancel)

private func matcher(phase: DictationPhase = .idle) -> HotkeyMatcher {
  var matcher = HotkeyMatcher(bindings: .chordFixture)
  matcher.phaseDidChange(to: phase)
  return matcher
}

struct HotkeyMatcherTests {
  @Test func extraModifierPasses() {
    var m = matcher()
    #expect(m.handle(.down(.l, [.command, .shift, .option])) == .pass)
    #expect(m.handle(.up(.l, [.command, .shift, .option])) == .pass)
  }

  @Test func missingModifierPasses() {
    var m = matcher()
    #expect(m.handle(.down(.l, [.command])) == .pass)
  }

  @Test func autorepeatOfOwnedKeyIsConsumedSilently() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    #expect(m.handle(.down(.l, cmdShift, isAutorepeat: true)) == consume)
    #expect(m.handle(.down(.l, cmdShift, isAutorepeat: true)) == consume)
  }

  @Test func autorepeatOfUnownedKeyPasses() {
    var m = matcher()
    #expect(m.handle(.down(.l, [], isAutorepeat: true)) == .pass)
  }

  @Test func pushToTalkKeyUpIgnoresModifiers() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    #expect(m.handle(.up(.l, [.shift])) == stop)
  }

  @Test(arguments: [
    KeyEvent.down(KeyCode(rawValue: 8), [.command]),
    .up(KeyCode(rawValue: 8), [.command]),
    .down(.space, [.command]),
    .down(.l, []),
  ])
  func unownedKeyPasses(event: KeyEvent) {
    var m = matcher()
    #expect(m.handle(event) == .pass)
  }

  @Test(arguments: [
    DictationPhase.idle, .complete, .failed(.aborted),
  ])
  func escapePassesWhenNothingToCancel(phase: DictationPhase) {
    var m = matcher(phase: phase)
    #expect(m.handle(.down(.escape, [])) == .pass)
    #expect(m.handle(.up(.escape, [])) == .pass)
  }

  @Test(arguments: [
    DictationPhase.starting(.toggle), .recording(.pushToTalk), .stopping, .transcribing,
    .awaitingManualPaste(until: HostTime(ticks: 1)),
  ])
  func escapeIsConsumedWhenCancellable(phase: DictationPhase) {
    var m = matcher(phase: phase)
    #expect(m.handle(.down(.escape, [])) == cancel)
    #expect(m.handle(.up(.escape, [])) == consume)
  }

  @Test func escapeUpAfterConsumedDownIsConsumedEvenIfPhaseDisarms() {
    var m = matcher(phase: .recording(.toggle))
    #expect(m.handle(.down(.escape, [])) == cancel)
    m.phaseDidChange(to: .idle)
    #expect(m.handle(.up(.escape, [])) == consume)
  }

  @Test func cancelReleasesHoldSilently() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    m.phaseDidChange(to: .recording(.pushToTalk))
    #expect(m.handle(.down(.escape, [])) == cancel)
    #expect(m.handle(.up(.escape, [])) == consume)
    #expect(m.handle(.up(.l, cmdShift)) == consume)
  }

  @Test func tapResetWhileHoldingStopsOnce() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    #expect(m.tapWasReset() == .pushToTalkStop)
    #expect(m.handle(.up(.l, cmdShift)) == consume)
    #expect(m.tapWasReset() == nil)
  }

  @Test func tapResetWithoutHoldEmitsNothing() {
    var m = matcher()
    #expect(m.tapWasReset() == nil)
  }

  @Test func keyUpAfterTapResetIsStillConsumed() {
    var m = matcher()
    #expect(m.handle(.down(.space, cmdShift)) == Verdict(.consume, emit: .toggle))
    #expect(m.tapWasReset() == nil)
    #expect(m.handle(.up(.space, cmdShift)) == consume)
  }

  @Test func freshUnownedDownOfPreviouslySwallowedKeyPasses() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    #expect(m.tapWasReset() == .pushToTalkStop)
    #expect(m.handle(.down(.l, [])) == .pass)
    #expect(m.handle(.down(.l, [], isAutorepeat: true)) == .pass)
    #expect(m.handle(.up(.l, [])) == .pass)
  }

  @Test func rePressAfterLostKeyUpStartsAgain() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    #expect(m.handle(.down(.l, cmdShift)) == start)
    #expect(m.handle(.up(.l, cmdShift)) == stop)
  }

  @Test func rebindWhileHoldingStopsAndKeepsPendingKeyUpConsumed() throws {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    let next = try HotkeyBindings([.pushToTalk: .chord(KeyChord(.v, [.control]))])
    #expect(m.rebind(next) == .pushToTalkStop)
    #expect(m.bindings == next)
    #expect(m.handle(.up(.l, cmdShift)) == consume)
    #expect(m.handle(.down(.l, cmdShift)) == .pass)
  }

  @Test func rebindWithoutHoldEmitsNothing() {
    var m = matcher()
    #expect(m.rebind(.chordFixture) == nil)
  }

  @Test func phaseChangeNeverReleasesHold() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    m.phaseDidChange(to: .idle)
    #expect(m.handle(.up(.l, cmdShift)) == stop)
  }

  @Test func pausedPassesEveryBoundChord() {
    var m = matcher(phase: .recording(.toggle))
    _ = m.setMode(.recording)
    for case .chord(let chord) in HotkeyBindings.chordFixture.triggers.values {
      #expect(m.handle(.down(chord.key, chord.modifiers)) == .pass)
      #expect(m.handle(.up(chord.key, chord.modifiers)) == .pass)
    }
  }

  @Test func holdStartedBeforePauseStillStopsOnKeyUp() {
    var m = matcher()
    #expect(m.handle(.down(.l, cmdShift)) == start)
    _ = m.setMode(.recording)
    #expect(m.handle(.down(.l, cmdShift, isAutorepeat: true)) == consume)
    #expect(m.handle(.up(.l, cmdShift)) == stop)
  }

  @Test func unpausingRestoresTheChords() {
    var m = matcher()
    _ = m.setMode(.recording)
    #expect(m.handle(.down(.space, cmdShift)) == .pass)
    _ = m.setMode(.live)
    #expect(m.handle(.down(.space, cmdShift)) == Verdict(.consume, emit: .toggle))
  }

  @Test(arguments: [
    DictationPhase.idle, .starting(.toggle), .recording(.toggle), .stopping, .transcribing,
    .awaitingManualPaste(until: HostTime(ticks: 1)), .complete, .failed(.captureError(.captureFailed)),
  ])
  func toggleAndPasteLastAreConsumedInEveryPhase(phase: DictationPhase) {
    var m = matcher(phase: phase)
    #expect(m.handle(.down(.space, cmdShift)) == Verdict(.consume, emit: .toggle))
    #expect(m.handle(.up(.space, cmdShift)) == consume)
    #expect(m.handle(.down(.v, cmdShift)) == Verdict(.consume, emit: .pasteLast))
    #expect(m.handle(.up(.v, cmdShift)) == consume)
  }

  @Test func `⌘V in the manual paste window is reported and still reaches the app`() {
    var m = matcher(phase: .awaitingManualPaste(until: HostTime(ticks: 1)))
    #expect(m.handle(.down(.v, [.command])) == Verdict(.pass, emit: .manualPaste))
    #expect(m.handle(.down(.v, [.command], isAutorepeat: true)) == .pass)
    #expect(m.handle(.up(.v, [.command])) == .pass)
    #expect(m.handle(.down(.v, [.command, .option])) == .pass)
  }

  @Test(arguments: [
    DictationPhase.idle, .starting(.toggle), .recording(.pushToTalk), .stopping, .transcribing, .pasting,
    .complete, .failed(.manualPasteExpired), .failed(.aborted),
  ])
  func `the ⌘V watcher is removed when the manual paste window closes`(phase: DictationPhase) {
    var m = matcher(phase: .awaitingManualPaste(until: HostTime(ticks: 1)))
    m.phaseDidChange(to: phase)
    #expect(m.handle(.down(.v, [.command])) == .pass)
  }
}

private let t0 = HostTime(ticks: 1_000_000_000)

private func at(_ ms: Int) -> HostTime {
  t0.advanced(by: .milliseconds(ms))
}

/// Default bindings with toggle on a double tap of ⌥, so ⌥Space still holds.
private func doubleTapMatcher(phase: DictationPhase = .idle) throws -> HotkeyMatcher {
  let bindings = try HotkeyBindings.defaults.replacing(.toggle, with: .doubleTap(.option))
  var matcher = HotkeyMatcher(bindings: bindings)
  matcher.phaseDidChange(to: phase)
  return matcher
}

/// Feeds `(event, ms)` pairs and returns every verdict.
private func feed(_ m: inout HotkeyMatcher, _ events: [(KeyEvent, Int)]) -> [Verdict] {
  events.map { m.handle($0.0, at: at($0.1)) }
}

private let option: Modifiers = [.option]

struct DoubleTapMatcherTests {
  @Test func `two clean option taps toggle on the second release and pass everything`() throws {
    var m = try doubleTapMatcher()
    let verdicts = feed(
      &m,
      [
        (.flags(option), 0), (.flags([]), 80),
        (.flags(option), 200), (.flags([]), 260),
      ])
    #expect(verdicts == [.pass, .pass, .pass, Verdict(.pass, emit: .toggle)])
  }

  @Test func `a tap then option with a key does not toggle`() throws {
    var m = try doubleTapMatcher()
    let f13 = KeyCode(rawValue: 105)
    let verdicts = feed(
      &m,
      [
        (.flags(option), 0), (.flags([]), 50),
        (.flags(option), 100), (.down(f13, option), 120), (.up(f13, option), 140),
        (.flags([]), 160),
      ])
    #expect(verdicts.allSatisfy { $0 == .pass })
  }

  @Test func `a tap reset mid gesture then a clean double tap toggles`() throws {
    var m = try doubleTapMatcher()
    _ = feed(&m, [(.flags(option), 0)])
    #expect(m.tapWasReset() == nil)
    let verdicts = feed(
      &m,
      [
        (.flags(option), 1000), (.flags([]), 1050),
        (.flags(option), 1100), (.flags([]), 1150),
      ])
    #expect(verdicts.last == Verdict(.pass, emit: .toggle))
  }

  @Test func `a third tap does not toggle again`() throws {
    var m = try doubleTapMatcher()
    let verdicts = feed(
      &m,
      [
        (.flags(option), 0), (.flags([]), 50),
        (.flags(option), 100), (.flags([]), 150),
        (.flags(option), 200), (.flags([]), 250),
      ])
    #expect(verdicts.flatMap(\.emits) == [.toggle])
  }

  static let ignored: [[(KeyEvent, Int)]] = [
    // A single tap.
    [(.flags(option), 0), (.flags([]), 80)],
    // The gap is longer than the window.
    [
      (.flags(option), 0), (.flags([]), 80),
      (.flags(option), 500), (.flags([]), 560),
    ],
    // The first press is held too long.
    [
      (.flags(option), 0), (.flags([]), 600),
      (.flags(option), 700),
    ],
    // A key between the taps.
    [
      (.flags(option), 0), (.flags([]), 50),
      (.down(.l, []), 80), (.up(.l, []), 90),
      (.flags(option), 120),
    ],
    // ⌥ plus a key, twice.
    [
      (.flags(option), 0), (.down(.l, option), 20), (.up(.l, option), 40),
      (.flags([]), 60),
      (.flags(option), 100),
    ],
    // ⌥ then ⌘ joins.
    [
      (.flags(option), 0), (.flags([.option, .command]), 20),
      (.flags(option), 40), (.flags([]), 60),
      (.flags(option), 100),
    ],
    // ⌥ tap then ⌘ tap.
    [
      (.flags(option), 0), (.flags([]), 50),
      (.flags([.command]), 100),
    ],
  ]

  @Test(arguments: 0..<ignored.count)
  func `near misses emit nothing and pass`(index: Int) throws {
    var m = try doubleTapMatcher()
    let verdicts = feed(&m, Self.ignored[index])
    #expect(verdicts.allSatisfy { $0 == .pass })
  }

  @Test func `unchanged flags between taps are ignored`() throws {
    var m = try doubleTapMatcher()
    let verdicts = feed(
      &m,
      [
        (.flags(option), 0), (.flags(option), 20),
        (.flags([]), 50), (.flags([]), 70),
        (.flags(option), 100), (.flags([]), 150),
      ])
    #expect(verdicts.last == Verdict(.pass, emit: .toggle))
  }

  @Test func `modifier events never release a held push-to-talk`() throws {
    var m = try doubleTapMatcher()
    #expect(m.handle(.down(.space, option), at: at(0)) == start)
    let verdicts = feed(
      &m,
      [
        (.flags([]), 20), (.flags(option), 40),
        (.flags([]), 60), (.flags(option), 80),
      ])
    #expect(verdicts.allSatisfy { $0.disposition == .pass && !$0.emits.contains(.pushToTalkStop) })
    #expect(m.handle(.up(.space, option), at: at(100)) == stop)
  }

  @Test func `paused emits nothing`() throws {
    var m = try doubleTapMatcher()
    _ = m.setMode(.recording)
    let verdicts = feed(
      &m,
      [
        (.flags(option), 0), (.flags([]), 50),
        (.flags(option), 100), (.flags([]), 150),
      ])
    #expect(verdicts.allSatisfy { $0 == .pass })
  }

  @Test(arguments: [(DictationPhase.idle, false), (.recording(.toggle), true)])
  func `double tap bound to cancel fires only while armed`(phase: DictationPhase, fires: Bool) throws {
    let bindings = try HotkeyBindings([.cancel: .doubleTap(.shift)])
    var m = HotkeyMatcher(bindings: bindings)
    m.phaseDidChange(to: phase)
    let verdicts = feed(
      &m,
      [
        (.flags([.shift]), 0), (.flags([]), 50),
        (.flags([.shift]), 100), (.flags([]), 150),
      ])
    #expect(verdicts.last == Verdict(.pass, emit: fires ? .cancel : nil))
  }

  @Test func `double tap bound to paste last emits paste last`() throws {
    var m = HotkeyMatcher(bindings: try HotkeyBindings([.pasteLast: .doubleTap(.control)]))
    let verdicts = feed(
      &m,
      [
        (.flags([.control]), 0), (.flags([]), 50),
        (.flags([.control]), 100), (.flags([]), 150),
      ])
    #expect(verdicts.last == Verdict(.pass, emit: .pasteLast))
  }

  @Test func `double tap cancel drops the hold without a stop`() throws {
    var m = HotkeyMatcher(
      bindings: try HotkeyBindings([
        .cancel: .doubleTap(.shift), .pushToTalk: .chord(KeyChord(.space, option)),
      ]))
    m.phaseDidChange(to: .recording(.pushToTalk))
    #expect(m.handle(.down(.space, option), at: at(0)) == start)
    let verdicts = feed(
      &m,
      [
        (.flags(option.union([.shift])), 10), (.flags(option), 30),
        (.flags([]), 40),
        (.flags([.shift]), 100), (.flags([]), 150),
        (.flags([.shift]), 200), (.flags([]), 250),
      ])
    #expect(verdicts.last == Verdict(.pass, emit: .cancel))
    #expect(m.handle(.up(.space, []), at: at(300)) == Verdict(.consume))
  }

  @Test func `a click between taps does not toggle`() throws {
    var m = try doubleTapMatcher()
    let verdicts = feed(
      &m,
      [
        (.flags(option), 0), (.flags([]), 50),
        (.pointerDown, 70),
        (.flags(option), 100), (.flags([]), 150),
      ])
    #expect(verdicts.allSatisfy { $0 == .pass })
  }
}
