import DictationCore
import Testing

@testable import Hotkeys

struct TrustedStampTests {
  private let now = HostTime(nanoseconds: 10_000_000_000)

  @Test func recentTimestampIsKept() {
    #expect(trustedStamp(9_900_000_000, now: now) == HostTime(nanoseconds: 9_900_000_000))
  }

  @Test func staleTimestampFallsBackToNow() {
    #expect(trustedStamp(8_000_000_000, now: now) == now)
  }

  @Test func zeroTimestampFallsBackToNow() {
    #expect(trustedStamp(0, now: now) == now)
  }

  @Test func futureTimestampFallsBackToNow() {
    #expect(trustedStamp(10_500_000_000, now: now) == now)
  }
}
