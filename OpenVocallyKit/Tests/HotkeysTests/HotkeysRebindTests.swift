import DictationCore
import Synchronization
import Testing

@testable import Hotkeys

private struct DiskFull: Error {}

private let commandOptionK = KeyChord(KeyCode(rawValue: 40), [.command, .option])
private let pushToTalk = KeyChord(.l, [.command, .shift])

/// Stands in for the system tap and records the order of its calls.
private final class FakeTap: Sendable {
  let enabled: Mutex<Bool>
  let calls = Mutex<[String]>([])

  init(enabled: Bool) {
    self.enabled = Mutex(enabled)
  }

  func control(onEnable: @escaping () -> Void = {}) -> EventTapControl {
    EventTapControl(
      isEnabled: { self.enabled.withLock { $0 } },
      enable: {
        self.calls.withLock { $0.append("enable") }
        self.enabled.withLock { $0 = true }
        onEnable()
      },
      disable: { self.calls.withLock { $0.append("disable") } })
  }
}

/// The grants the tap checks, switchable mid-test.
private final class Trust: Sendable {
  let granted: Mutex<Bool>

  init(_ granted: Bool) {
    self.granted = Mutex(granted)
  }

  var check: @Sendable () -> Bool { { self.granted.withLock { $0 } } }
}

private func firstCommands(_ hotkeys: Hotkeys, _ count: Int) async -> [DictationCommand] {
  var commands: [DictationCommand] = []
  for await event in hotkeys.events {
    commands.append(event.command)
    if commands.count == count { break }
  }
  return commands
}

struct HotkeysRebindTests {
  @Test func rebindPersistsThenSwaps() throws {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    var persisted: [HotkeyBindings] = []
    try hotkeys.rebind(.toggle, to: .chord(commandOptionK)) { persisted.append($0) }
    #expect(hotkeys.bindings.trigger(for: .toggle) == .chord(commandOptionK))
    #expect(persisted == [hotkeys.bindings])
  }

  @Test func persistFailureLeavesBindingsUnchanged() {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    #expect(throws: RebindError.persistFailed) {
      try hotkeys.rebind(.toggle, to: .chord(commandOptionK)) { _ in throw DiskFull() }
    }
    #expect(hotkeys.bindings == .chordFixture)
  }

  @Test func duplicateNamesTheOwnerAndChangesNothing() {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    var persistCalls = 0
    #expect(throws: RebindError.invalid(.duplicate(.chord(pushToTalk), owner: .pushToTalk))) {
      try hotkeys.rebind(.toggle, to: .chord(pushToTalk)) { _ in persistCalls += 1 }
    }
    #expect(persistCalls == 0)
    #expect(hotkeys.bindings == .chordFixture)
  }

  @Test func unsafeChordIsRejectedAndChangesNothing() {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    var persistCalls = 0
    #expect(throws: RebindError.invalid(.unsafe(.paste))) {
      try hotkeys.rebind(.pasteLast, to: .chord(KeyChord(.v, [.command]))) { _ in persistCalls += 1 }
    }
    #expect(persistCalls == 0)
    #expect(hotkeys.bindings == .chordFixture)
  }

  @Test func noOpRebindNeitherPersistsNorReleasesAHold() throws {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    #expect(hotkeys.handle(.down(.l, [.command, .shift])).emits == [.pushToTalkStart])
    var persistCalls = 0
    try hotkeys.rebind(.pushToTalk, to: .chord(pushToTalk)) { _ in persistCalls += 1 }
    #expect(persistCalls == 0)
    #expect(hotkeys.handle(.up(.l, [.command, .shift])).emits == [.pushToTalkStop])
  }

  @Test func replacedBindingsAreTheBaseOfTheNextRebind() throws {
    let hotkeys = Hotkeys(bindings: .defaults)
    hotkeys.replaceBindings(.chordFixture)
    #expect(hotkeys.bindings == .chordFixture)
    var persisted: [HotkeyBindings] = []
    try hotkeys.rebind(.toggle, to: .chord(commandOptionK)) { persisted.append($0) }
    #expect(persisted == [try HotkeyBindings.chordFixture.replacing(.toggle, with: .chord(commandOptionK))])
  }

  @Test func replaceBindingsReleasesAHeldPushToTalk() async {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    _ = hotkeys.handle(.down(.l, [.command, .shift]))
    hotkeys.replaceBindings(.defaults)
    let commands = await firstCommands(hotkeys, 2)
    #expect(commands == [.pushToTalkStart, .pushToTalkStop])
  }

  @Test func ensureEnabledOnAnEnabledTapKeepsTheHold() async {
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: { true })
    let tap = FakeTap(enabled: true)
    hotkeys.attachTap { tap.control() }
    #expect(hotkeys.handle(.down(.l, [.command, .shift])).emits == [.pushToTalkStart])
    #expect(await hotkeys.ensureEnabled())
    #expect(tap.calls.withLock { $0 }.isEmpty)
    #expect(hotkeys.handle(.up(.l, [.command, .shift])).emits == [.pushToTalkStop])
  }

  /// A press the re-enabled tap delivers right away must survive the reset.
  @Test func ensureEnabledReleasesTheHoldBeforeEnabling() async {
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: { true })
    let tap = FakeTap(enabled: false)
    hotkeys.attachTap {
      tap.control { _ = hotkeys.handle(.down(.l, [.command, .shift])) }
    }
    _ = hotkeys.handle(.down(.l, [.command, .shift]))
    await hotkeys.ensureEnabled()
    #expect(tap.calls.withLock { $0 } == ["enable"])
    let commands = await firstCommands(hotkeys, 3)
    #expect(commands == [.pushToTalkStart, .pushToTalkStop, .pushToTalkStart])
  }

  /// The system disables a tap whose callback stalls; the next push-to-talk must not stay held.
  @Test func tapDisabledByTimeoutReleasesTheHoldAndReEnables() async {
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: { true })
    let tap = FakeTap(enabled: false)
    hotkeys.attachTap { tap.control() }
    _ = hotkeys.handle(.down(.l, [.command, .shift]))
    hotkeys.tapWasDisabled(.tapDisabledByTimeout)
    #expect(tap.calls.withLock { $0 } == ["enable"])
    #expect(tap.enabled.withLock { $0 })
    let commands = await firstCommands(hotkeys, 2)
    #expect(commands == [.pushToTalkStart, .pushToTalkStop])
  }
}

/// Without the right to post events, WindowServer drops every event an active tap passes, so
/// re-enabling it would freeze all input on the Mac.
struct HotkeysTrustTests {
  @Test func `a timeout without the grants removes the tap instead of re-enabling it`() async {
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: { false })
    let tap = FakeTap(enabled: false)
    hotkeys.attachTap { tap.control() }
    _ = hotkeys.handle(.down(.l, [.command, .shift]))
    hotkeys.tapWasDisabled(.tapDisabledByTimeout)
    #expect(tap.calls.withLock { $0 } == ["disable"])
    #expect(await firstCommands(hotkeys, 2) == [.pushToTalkStart, .pushToTalkStop])
  }

  @Test func `a check without the grants removes an enabled tap`() async {
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: { false })
    let tap = FakeTap(enabled: true)
    hotkeys.attachTap { tap.control() }
    #expect(await hotkeys.ensureEnabled() == false)
    #expect(tap.calls.withLock { $0 } == ["disable"])
    #expect(await hotkeys.ensureEnabled() == false)
    #expect(tap.calls.withLock { $0 } == ["disable"])
  }

  @Test func `a check reinstalls the tap once the grants are back`() async {
    let trust = Trust(true)
    let first = FakeTap(enabled: true)
    let second = FakeTap(enabled: true)
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: trust.check) { hotkeys in
      hotkeys.attachTap { second.control() }
    }
    hotkeys.attachTap { first.control() }
    trust.granted.withLock { $0 = false }
    #expect(await hotkeys.ensureEnabled() == false)
    trust.granted.withLock { $0 = true }
    #expect(await hotkeys.ensureEnabled())
    #expect(first.calls.withLock { $0 } == ["disable"])
    hotkeys.stop()
    #expect(second.calls.withLock { $0 } == ["disable"])
  }

  @Test func `a failed reinstall stays suspended and tries again`() async {
    let trust = Trust(false)
    let installs = DisableCount()
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: trust.check) { _ in
      installs.value.withLock { $0 += 1 }
      return false
    }
    hotkeys.attachTap { FakeTap(enabled: true).control() }
    #expect(await hotkeys.ensureEnabled() == false)
    trust.granted.withLock { $0 = true }
    #expect(await hotkeys.ensureEnabled() == false)
    #expect(await hotkeys.ensureEnabled() == false)
    #expect(installs.value.withLock { $0 } == 2)
    hotkeys.stop()
    #expect(await hotkeys.ensureEnabled() == false)
    #expect(installs.value.withLock { $0 } == 2)
  }

  @Test func `no tap installs after stop`() async {
    let hotkeys = Hotkeys(bindings: .chordFixture, isTrusted: { true })
    hotkeys.stop()
    #expect(hotkeys.attachTap { FakeTap(enabled: true).control() } == false)
    #expect(await hotkeys.ensureEnabled() == false)
  }
}

/// A reference the tap's closures can share, so the control they build is free to cross
/// into `Hotkeys`. A local `Mutex` captured by those closures is not.
private final class DisableCount: Sendable {
  let value = Mutex(0)
}

struct HotkeysStopTests {
  @Test func `stop disables the tap once and ends events`() async {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    let disables = DisableCount()
    hotkeys.attachTap {
      EventTapControl(isEnabled: { true }, enable: {}, disable: { disables.value.withLock { $0 += 1 } })
    }
    hotkeys.stop()
    hotkeys.stop()
    var received = 0
    for await _ in hotkeys.events { received += 1 }
    #expect(received == 0)
    #expect(disables.value.withLock { $0 } == 1)
  }
}
