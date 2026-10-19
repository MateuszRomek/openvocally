import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct InputDevicePolicyTests {
  private func device(
    _ uid: String, alive: Bool = true, input: Bool = true, aggregate: Bool = false
  ) -> InputDevice {
    InputDevice(uid: uid, id: 1, isAlive: alive, hasInput: input, isAggregateOrVirtual: aggregate)
  }

  @Test func `saved device wins when alive with input`() {
    let devices = [device("default"), device("usb")]
    #expect(InputDevicePolicy.select(saved: "usb", systemDefault: "default", devices: devices)?.uid == "usb")
  }

  @Test(arguments: [(true, false), (false, true)])
  func `unusable saved device falls back to the system default`(alive: Bool, input: Bool) {
    let devices = [device("usb", alive: alive, input: input), device("default")]
    #expect(
      InputDevicePolicy.select(saved: "usb", systemDefault: "default", devices: devices)?.uid == "default")
  }

  @Test func `missing saved and default fall back to the first real input device`() {
    let devices = [
      device("speakers", input: false), device("loopback", aggregate: true), device("dead", alive: false),
      device("mic"),
    ]
    #expect(InputDevicePolicy.select(saved: "gone", systemDefault: nil, devices: devices)?.uid == "mic")
  }

  @Test func `no usable device selects nothing`() {
    let devices = [device("speakers", input: false), device("loopback", aggregate: true)]
    #expect(InputDevicePolicy.select(saved: nil, systemDefault: nil, devices: devices) == nil)
  }
}
