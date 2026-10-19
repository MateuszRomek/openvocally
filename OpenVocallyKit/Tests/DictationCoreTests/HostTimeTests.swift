import Darwin
import Testing

@testable import DictationCore

struct HostTimeTests {
  @Test func `nanoseconds on the uptime clock land on the same instant as mach ticks`() {
    let stamp = HostTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    let age = HostTime.now().milliseconds(since: stamp)
    #expect(age >= 0 && age < 5)
  }

  @Test func `advancing and measuring round-trip`() {
    let press = HostTime(ticks: 10_000_000_000)
    let later = press.advanced(by: .milliseconds(10))
    #expect(abs(later.milliseconds(since: press) - 10) < 0.001)
    #expect(abs(press.milliseconds(since: later) + 10) < 0.001)
    #expect(later > press)
  }
}
