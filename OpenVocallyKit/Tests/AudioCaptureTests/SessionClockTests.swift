import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct SessionClockTests {
  @Test func `a host clock timestamp converts to the same host time`() {
    let hostClock = CMClockGetHostTimeClock()
    let before = HostTime.now()
    let converted = SessionClock.hostTime(of: CMClockGetTime(hostClock))
    let after = HostTime.now()
    #expect(converted >= before.advanced(by: .microseconds(-1)))
    #expect(converted <= after.advanced(by: .microseconds(1)))
  }
}
