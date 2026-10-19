import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct DeviceChangeActionTests {
  private let usb = InputDevice(uid: "usb", id: 2, isAlive: true, hasInput: true, isAggregateOrVirtual: false)
  private let builtIn = InputDevice(
    uid: "built-in", id: 1, isAlive: true, hasInput: true, isAggregateOrVirtual: false)

  @Test func `the recording device unplugged interrupts the recording`() {
    let action = DeviceChangeAction.decide(
      recording: true, active: usb, selected: builtIn, devices: [builtIn])
    #expect(action == .interrupt)
  }

  @Test func `a recording device that died interrupts the recording`() {
    let dead = InputDevice(uid: "usb", id: 2, isAlive: false, hasInput: true, isAggregateOrVirtual: false)
    let action = DeviceChangeAction.decide(
      recording: true, active: usb, selected: builtIn, devices: [builtIn, dead])
    #expect(action == .interrupt)
  }

  @Test func `a new default while recording waits for the recording to end`() {
    let action = DeviceChangeAction.decide(
      recording: true, active: builtIn, selected: usb, devices: [builtIn, usb])
    #expect(action == .none)
  }

  @Test func `a recording with no device yet ignores device changes`() {
    let action = DeviceChangeAction.decide(recording: true, active: nil, selected: usb, devices: [usb])
    #expect(action == .none)
  }

  @Test func `idle with no device reselects`() {
    let action = DeviceChangeAction.decide(recording: false, active: nil, selected: usb, devices: [usb])
    #expect(action == .reselect)
  }

  @Test func `presence needs the same uid and a usable device`() {
    let dead = InputDevice(uid: "usb", id: 2, isAlive: false, hasInput: true, isAggregateOrVirtual: false)
    #expect(DeviceChangeAction.isPresent(usb, in: [builtIn, usb]))
    #expect(!DeviceChangeAction.isPresent(usb, in: [builtIn, dead]))
  }

  @Test func `an unrelated change while recording does nothing`() {
    let action = DeviceChangeAction.decide(
      recording: true, active: builtIn, selected: builtIn, devices: [builtIn, usb])
    #expect(action == .none)
  }

  @Test func `a new default while idle reselects`() {
    let action = DeviceChangeAction.decide(
      recording: false, active: builtIn, selected: usb, devices: [builtIn, usb])
    #expect(action == .reselect)
  }

  @Test func `the idle device unplugged reselects`() {
    let action = DeviceChangeAction.decide(
      recording: false, active: usb, selected: builtIn, devices: [builtIn])
    #expect(action == .reselect)
  }

  @Test func `an unrelated change while idle keeps the warm mic`() {
    let action = DeviceChangeAction.decide(
      recording: false, active: builtIn, selected: builtIn, devices: [builtIn, usb])
    #expect(action == .none)
  }
}
