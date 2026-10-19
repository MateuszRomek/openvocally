import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct MicLifecycleTests {
  let now = ContinuousClock.now

  @Test func `successful stop keeps the mic warm for 15 s`() {
    var mic = MicLifecycle()
    mic.start()
    #expect(mic.stop(now: now, warm: .seconds(15)) == .keepWarm(until: now.advanced(by: .seconds(15))))
    mic.start()
    #expect(mic.isRecording)
  }

  @Test func `zero warm duration releases after every stop`() {
    var mic = MicLifecycle()
    mic.start()
    #expect(mic.stop(now: now, warm: .zero) == .stopMic)
    #expect(mic.state == .closed)
  }

  @Test func `release stops a recording or warm mic once`() {
    var recording = MicLifecycle()
    recording.start()
    #expect(recording.release() == .stopMic)
    #expect(recording.state == .closed)

    var warm = MicLifecycle()
    warm.start()
    _ = warm.stop(now: now, warm: .seconds(15))
    #expect(warm.release() == .stopMic)
    #expect(warm.release() == .none)
  }

  @Test func `warm expiry stops only after the deadline`() {
    var mic = MicLifecycle()
    mic.start()
    _ = mic.stop(now: now, warm: .seconds(15))
    #expect(mic.warmExpired(now: now.advanced(by: .seconds(14))) == .none)
    #expect(mic.warmExpired(now: now.advanced(by: .seconds(15))) == .stopMic)
    #expect(mic.state == .closed)
  }

  @Test func `a stale warm timer is ignored`() {
    var mic = MicLifecycle()
    mic.start()
    _ = mic.stop(now: now, warm: .seconds(15))
    mic.start()
    _ = mic.stop(now: now.advanced(by: .seconds(10)), warm: .seconds(15))
    #expect(mic.warmExpired(now: now.advanced(by: .seconds(15))) == .none)
    mic.start()
    #expect(mic.warmExpired(now: now.advanced(by: .seconds(30))) == .none)
    #expect(mic.isRecording)
  }
}
