import DictationCore
import Foundation
import Testing

@testable import SoundCues

struct CueGateTests {
  private let now = ContinuousClock.now
  private let loud = SoundCueSettings(volume: 1)

  @Test func `a start cue that waited over 300 ms is stale`() {
    #expect(!CueGate.isStale(.start, enqueuedAt: now, now: now.advanced(by: .milliseconds(300))))
    #expect(CueGate.isStale(.start, enqueuedAt: now, now: now.advanced(by: .milliseconds(301))))
  }

  @Test func `cancel and error cues are never stale`() {
    #expect(!CueGate.isStale(.cancel, enqueuedAt: now, now: now.advanced(by: .seconds(2))))
    #expect(!CueGate.isStale(.error, enqueuedAt: now, now: now.advanced(by: .seconds(2))))
  }

  @Test func `a start cue 340 ms before an output change replays`() {
    #expect(CueGate.shouldReplay(.start, scheduledAt: now, changedAt: now.advanced(by: .milliseconds(340))))
  }

  @Test func `a start cue 600 ms before an output change does not replay`() {
    #expect(!CueGate.shouldReplay(.start, scheduledAt: now, changedAt: now.advanced(by: .milliseconds(600))))
  }

  @Test func `an error cue never replays`() {
    #expect(!CueGate.shouldReplay(.error, scheduledAt: now, changedAt: now.advanced(by: .milliseconds(340))))
  }

  @Test func `an output change before the start cue was scheduled does not replay it`() {
    #expect(!CueGate.shouldReplay(.start, scheduledAt: now, changedAt: now.advanced(by: .milliseconds(-100))))
  }

  @Test func `a second start within 85 ms is dropped`() {
    var gate = CueGate()
    #expect(gate.admit(.start, at: now, settings: loud) == 1)
    #expect(gate.admit(.start, at: now.advanced(by: .milliseconds(84)), settings: loud) == nil)
    #expect(gate.admit(.start, at: now.advanced(by: .milliseconds(85)), settings: loud) == 1)
  }

  @Test func `a second cancel within 140 ms is dropped`() {
    var gate = CueGate()
    #expect(gate.admit(.cancel, at: now, settings: loud) != nil)
    #expect(gate.admit(.cancel, at: now.advanced(by: .milliseconds(139)), settings: loud) == nil)
    #expect(gate.admit(.cancel, at: now.advanced(by: .milliseconds(140)), settings: loud) != nil)
  }

  @Test func `errors are never gated`() {
    var gate = CueGate()
    #expect(gate.admit(.error, at: now, settings: loud) == 1)
    #expect(gate.admit(.error, at: now, settings: loud) == 1)
  }

  @Test func `different cues do not share a cooldown`() {
    var gate = CueGate()
    #expect(gate.admit(.start, at: now, settings: loud) != nil)
    #expect(gate.admit(.cancel, at: now, settings: loud) != nil)
  }

  @Test func `disabled or muted cues stay silent`() {
    var gate = CueGate()
    #expect(gate.admit(.error, at: now, settings: SoundCueSettings(enabled: false)) == nil)
    #expect(gate.admit(.error, at: now, settings: SoundCueSettings(volume: 0)) == nil)
  }

  @Test func `cancel plays at 70 percent of the volume`() throws {
    var gate = CueGate()
    let admitted = gate.admit(.cancel, at: now, settings: SoundCueSettings(volume: 0.5))
    let gain = try #require(admitted)
    #expect(abs(gain - 0.35) < 0.0001)
    #expect(gate.admit(.start, at: now, settings: SoundCueSettings(volume: 0.5)) == 0.5)
  }
}

struct SoundCueSettingsTests {
  @Test(arguments: [(1.3, 1.0), (-1, 0), (0.33, 0.35), (.nan, 0.8), (.infinity, 0.8), (0.5, 0.5)])
  func `volume is clamped and snapped to 5 percent steps`(raw: Double, expected: Double) {
    #expect(SoundCueSettings(volume: raw).volume == expected)
  }

  @Test func `missing defaults mean on at the default volume`() throws {
    let defaults = try #require(UserDefaults(suiteName: "SoundCueSettingsTests-\(UUID())"))
    #expect(SoundCueSettings.load(from: defaults) == SoundCueSettings(enabled: true, volume: 0.8))
    defaults.set(false, forKey: SoundCueSettings.enabledKey)
    defaults.set(0.42, forKey: SoundCueSettings.volumeKey)
    #expect(SoundCueSettings.load(from: defaults) == SoundCueSettings(enabled: false, volume: 0.4))
  }
}
