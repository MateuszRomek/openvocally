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
      })
  }
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

  @Test func ensureEnabledOnAnEnabledTapKeepsTheHold() {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    let tap = FakeTap(enabled: true)
    hotkeys.attachTap { tap.control() }
    #expect(hotkeys.handle(.down(.l, [.command, .shift])).emits == [.pushToTalkStart])
    hotkeys.ensureEnabled()
    #expect(tap.calls.withLock { $0 }.isEmpty)
    #expect(hotkeys.handle(.up(.l, [.command, .shift])).emits == [.pushToTalkStop])
  }

  /// A press the re-enabled tap delivers right away must survive the reset.
  @Test func ensureEnabledReleasesTheHoldBeforeEnabling() async {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    let tap = FakeTap(enabled: false)
    hotkeys.attachTap {
      tap.control { _ = hotkeys.handle(.down(.l, [.command, .shift])) }
    }
    _ = hotkeys.handle(.down(.l, [.command, .shift]))
    hotkeys.ensureEnabled()
    #expect(tap.calls.withLock { $0 } == ["enable"])
    let commands = await firstCommands(hotkeys, 3)
    #expect(commands == [.pushToTalkStart, .pushToTalkStop, .pushToTalkStart])
  }

  /// The system disables a tap whose callback stalls; the next push-to-talk must not stay held.
  @Test func tapDisabledByTimeoutReleasesTheHoldAndReEnables() async {
    let hotkeys = Hotkeys(bindings: .chordFixture)
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

struct HotkeysStopTests {
  @Test func `stop disables the tap once and ends events`() async {
    let hotkeys = Hotkeys(bindings: .chordFixture)
    let disables = Mutex(0)
    hotkeys.attachTap {
      EventTapControl(isEnabled: { true }, enable: {}, disable: { disables.withLock { $0 += 1 } })
    }
    hotkeys.stop()
    hotkeys.stop()
    var received = 0
    for await _ in hotkeys.events { received += 1 }
    #expect(received == 0)
    #expect(disables.withLock { $0 } == 1)
  }
}
