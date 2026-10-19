import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct WarmWindowTests {
  @Test(arguments: [
    (Microphone.Transport?.some(.bluetooth), Duration.seconds(5)),
    (.some(.builtIn), .seconds(15)),
    (.some(.usb), .seconds(15)),
    (.some(.other), .seconds(15)),
    (nil, .seconds(15)),
  ])
  func `only a Bluetooth mic closes after 5 s`(transport: Microphone.Transport?, warm: Duration) {
    #expect(CaptureLimits.warm(base: .seconds(15), transport: transport) == warm)
  }

  @Test func `a shorter base stays as it is on Bluetooth`() {
    #expect(CaptureLimits.warm(base: .seconds(2), transport: .bluetooth) == .seconds(2))
  }
}

struct WatchdogLimitTests {
  @Test(arguments: [
    (Microphone.Transport?.some(.bluetooth), Duration.seconds(10)),
    (.builtIn, .seconds(5)),
    (.usb, .seconds(5)),
    (.other, .seconds(5)),
    (nil, .seconds(5)),
  ])
  func `only a Bluetooth mic gets the longer limit`(transport: Microphone.Transport?, limit: Duration) {
    #expect(CaptureLimits.watchdog(base: .seconds(5), transport: transport) == limit)
  }
}
