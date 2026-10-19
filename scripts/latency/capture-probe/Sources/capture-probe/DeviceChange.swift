import AVFoundation
import AudioCapture
import CoreAudio
import DictationCore
import Foundation
import OSLog
import Synchronization

/// Hardware check that a device change mid-session keeps capture working. In cases 1 to 3 a private aggregate stands in for a USB mic:
/// creating it is a plug-in, destroying it an unplug. It wraps a physical mic other than the
/// system default when there is one, because an aggregate over the mic that is recording
/// reconfigures that mic, which a real plug-in never does. Changing the aggregate's subdevices
/// mid-recording did not stop the engine, so case 4 needs a real Bluetooth headset.
struct ScenarioResult: Encodable {
  let scenario: String
  let passed: Bool
  let detail: String
  var peak: Float?
  var keptMs: Double?
}

struct FakeMic {
  let id: AudioObjectID

  /// A fresh UID per case: re-creating an aggregate under a UID this process already used
  /// failed the engine's device switch with -10851 on every other case.
  static func makeUID() -> String { "com.openvocally.capture-probe.fake-mic.\(UUID().uuidString)" }

  static func plugIn(uid: String) throws(ProbeError) -> FakeMic {
    guard
      let source = inputUIDs(transports: [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB])
        .first
    else { throw .setup("no physical microphone") }
    let description: [String: Any] = [
      kAudioAggregateDeviceUIDKey: uid,
      kAudioAggregateDeviceNameKey: "Capture probe fake mic",
      kAudioAggregateDeviceIsPrivateKey: 1,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: source]],
      kAudioAggregateDeviceMainSubDeviceKey: source,
    ]
    var id = AudioObjectID(0)
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
    guard status == noErr else { throw .setup("creating the fake mic failed with \(status)") }
    return FakeMic(id: id)
  }

  func unplug() {
    _ = AudioHardwareDestroyAggregateDevice(id)
  }
}

private func inputUIDs(transports: [UInt32]) -> [String] {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  let system = AudioObjectID(kAudioObjectSystemObject)
  guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
  var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
  guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
  let defaultUID = defaultInputUID()
  var uids: [String] = []
  for id in ids {
    var transport: UInt32 = 0
    var transportSize = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyTransportType
    address.mScope = kAudioObjectPropertyScopeGlobal
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &transportSize, &transport) == noErr,
      transports.contains(transport)
    else { continue }
    address.mSelector = kAudioDevicePropertyStreams
    address.mScope = kAudioObjectPropertyScopeInput
    var streamsSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &streamsSize) == noErr, streamsSize > 0 else {
      continue
    }
    address.mSelector = kAudioDevicePropertyDeviceUID
    address.mScope = kAudioObjectPropertyScopeGlobal
    var uid: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &uidSize, &uid) == noErr, let uid else { continue }
    uids.append(uid.takeRetainedValue() as String)
  }
  return uids.filter { $0 != defaultUID } + uids.filter { $0 == defaultUID }
}

private func defaultInputUID() -> String? {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var id = AudioDeviceID(0)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  guard
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
  else { return nil }
  address.mSelector = kAudioDevicePropertyDeviceUID
  var uid: Unmanaged<CFString>?
  var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(id, &address, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
  return uid.takeRetainedValue() as String
}

private final class InterruptionBox: Sendable {
  let error = Mutex<CaptureError?>(nil)
}

private struct Press {
  let wasWarm: Bool
  let pressToEngineRunningMs: Double
  let samples: Int
  let peak: Float
  let deviceRunning: Bool?

  /// A wired mic never returns exact zeros, so a peak of 0 means the audio never arrived.
  var heardSomething: Bool { samples > 0 && peak > 0 }
}

func peak(_ samples: [Float]) -> Float {
  samples.lazy.map(abs).max() ?? 0
}

private func press(_ capture: AudioCapture, device uid: String?) async throws(CaptureError) -> Press {
  let pressed = HostTime.now()
  let started = try await capture.start(pressedAt: pressed)
  try? await Task.sleep(for: .milliseconds(500))
  let running = deviceRunningSomewhere(uid: uid)
  let recording = try await capture.stop(releasedAt: HostTime.now())
  return Press(
    wasWarm: started.wasWarm, pressToEngineRunningMs: started.micRunningAt.milliseconds(since: pressed),
    samples: recording.samples.count, peak: peak(recording.samples), deviceRunning: running)
}

private func settle() async {
  try? await Task.sleep(for: .seconds(1))
}

private func describe(_ press: Press) -> String {
  "next press: engine running after \(String(format: "%.1f", press.pressToEngineRunningMs)) ms, "
    + "warm \(press.wasWarm), \(press.samples) samples, peak \(String(format: "%.4f", press.peak)), expected device running \(press.deviceRunning.map(String.init) ?? "unknown")"
}

private func unplugDuringRecording() async -> ScenarioResult {
  let name = "1 unplug during recording"
  let fakeUID = FakeMic.makeUID()
  do {
    let mic = try FakeMic.plugIn(uid: fakeUID)
    defer { mic.unplug() }
    await settle()
    let capture = AudioCapture()
    try await capture.prepare(deviceUID: fakeUID)
    let box = InterruptionBox()
    _ = try await capture.start(pressedAt: HostTime.now()) { error in box.error.withLock { $0 = error } }
    try? await Task.sleep(for: .milliseconds(300))
    guard deviceRunningSomewhere(uid: fakeUID) == true else {
      return ScenarioResult(
        scenario: name, passed: false, detail: "the recording did not run on the fake mic")
    }
    mic.unplug()
    try? await Task.sleep(for: .seconds(2))
    let reported = box.error.withLock { $0 }
    var stopError: CaptureError?
    do throws(CaptureError) {
      _ = try await capture.stop(releasedAt: HostTime.now())
    } catch {
      stopError = error
    }
    await settle()
    let next = try await press(capture, device: nil)
    let passed =
      reported == .deviceLost && stopError == .notRecording && next.heardSomething
      && next.deviceRunning == true
    return ScenarioResult(
      scenario: name, passed: passed,
      detail:
        "interruption \(reported.map { "\($0)" } ?? "none"), stop threw \(stopError.map { "\($0)" } ?? "nothing"); "
        + describe(next))
  } catch {
    return ScenarioResult(scenario: name, passed: false, detail: "\(error)")
  }
}

private func plugInWhileWarm() async -> ScenarioResult {
  let name = "2 plug in while warm"
  let fakeUID = FakeMic.makeUID()
  do {
    // The app closes the mic at stop, but this case keeps the warm path covered.
    let capture = AudioCapture(warmDuration: .seconds(15))
    try await capture.prepare(deviceUID: fakeUID)
    let first = try await press(capture, device: nil)
    let mic = try FakeMic.plugIn(uid: fakeUID)
    defer { mic.unplug() }
    await settle()
    let next = try await press(capture, device: fakeUID)
    let passed =
      first.heardSomething && next.heardSomething && next.deviceRunning == true
      && next.pressToEngineRunningMs < 100
    return ScenarioResult(scenario: name, passed: passed, detail: describe(next))
  } catch {
    return ScenarioResult(scenario: name, passed: false, detail: "\(error)")
  }
}

private func plugInDuringRecording() async -> ScenarioResult {
  let name = "3 plug in during recording"
  let fakeUID = FakeMic.makeUID()
  do {
    let capture = AudioCapture()
    try await capture.prepare(deviceUID: fakeUID)
    let box = InterruptionBox()
    _ = try await capture.start(pressedAt: HostTime.now()) { error in box.error.withLock { $0 = error } }
    try? await Task.sleep(for: .milliseconds(300))
    let mic = try FakeMic.plugIn(uid: fakeUID)
    defer { mic.unplug() }
    try? await Task.sleep(for: .milliseconds(1_000))
    let recording: Recording
    do throws(CaptureError) {
      recording = try await capture.stop(releasedAt: HostTime.now())
    } catch {
      return ScenarioResult(scenario: name, passed: false, detail: "the recording's stop threw \(error)")
    }
    let keptMs = recording.keptDuration / .milliseconds(1)
    let reported = box.error.withLock { $0 }
    await settle()
    let next = try await press(capture, device: fakeUID)
    let recordingPeak = peak(recording.samples)
    let passed =
      reported == nil && keptMs > 1_100 && recordingPeak > 0 && next.heardSomething
      && next.deviceRunning == true
    return ScenarioResult(
      scenario: name, passed: passed,
      detail:
        "recording kept \(String(format: "%.0f", keptMs)) ms of 1300, peak \(String(format: "%.4f", recordingPeak)), interruption \(reported.map { "\($0)" } ?? "none"); "
        + describe(next))
  } catch {
    return ScenarioResult(scenario: name, passed: false, detail: "\(error)")
  }
}

/// Audio already playing on the headset when the press opens its mic forces the switch from the
/// playback to the headset profile. On AirPods Pro the switch lands in the start, not mid-recording:
/// audio that starts during a recording never stopped the engine.
private func bluetoothProfileSwitch() async -> ScenarioResult {
  let name = "4 Bluetooth profile switch at the press"
  do {
    guard
      let headset = inputUIDs(transports: [
        kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
      ])
      .first
    else { throw ProbeError.setup("case 4 needs a connected Bluetooth headset with a mic, such as AirPods") }
    let capture = AudioCapture()
    let prepareStart = HostTime.now()
    try await capture.prepare(deviceUID: headset)
    let prepareMs = HostTime.now().milliseconds(since: prepareStart)
    try? await Task.sleep(for: .seconds(1))
    let player = try AVAudioPlayer(contentsOf: URL(filePath: "/System/Library/Sounds/Submarine.aiff"))
    player.numberOfLoops = -1
    player.volume = 0.3
    player.play()
    defer { player.stop() }
    try? await Task.sleep(for: .seconds(1))
    let since = Date()
    let box = InterruptionBox()
    let pressed = HostTime.now()
    let started = try await capture.start(pressedAt: pressed) { error in box.error.withLock { $0 = error } }
    let pressToMicMs = started.micRunningAt.milliseconds(since: pressed)
    try? await Task.sleep(for: .seconds(2))
    let running = deviceRunningSomewhere(uid: headset)
    let recording = try await capture.stop(releasedAt: HostTime.now())
    let keptMs = recording.keptDuration / .milliseconds(1)
    let reported = box.error.withLock { $0 }
    let log = try captureLog(since: since)
    let recordingPeak = peak(recording.samples)
    return ScenarioResult(
      scenario: name, passed: reported == nil && running == true && keptMs > 1_700,
      detail:
        "prepare \(String(format: "%.0f", prepareMs)) ms, engine running \(String(format: "%.0f", pressToMicMs)) ms after the press, recording kept \(String(format: "%.0f", keptMs)) ms of 2000, peak \(String(format: "%.4f", recordingPeak)), interruption \(reported.map { "\($0)" } ?? "none"), "
        + "headset running at the end \(running.map(String.init) ?? "unknown"); log: "
        + log.joined(separator: " | "),
      peak: recordingPeak, keptMs: keptMs)
  } catch {
    return ScenarioResult(scenario: name, passed: false, detail: "\(error)")
  }
}

/// Reproduces a switch from AirPods to the built-in mic in Settings where the next press waited
/// for the mic. Records on the headset with sound playing, switches, then times the next press.
private func switchFromBluetoothToBuiltIn() async -> ScenarioResult {
  let name = "5 switch from a Bluetooth headset to the built-in mic"
  do {
    guard
      let headset = inputUIDs(transports: [
        kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
      ])
      .first
    else { throw ProbeError.setup("case 5 needs a connected Bluetooth headset with a mic, such as AirPods") }
    guard let builtIn = inputUIDs(transports: [kAudioDeviceTransportTypeBuiltIn]).first else {
      throw ProbeError.setup("case 5 needs the built-in mic")
    }
    let capture = AudioCapture()
    try await capture.prepare(deviceUID: headset)
    let player = try AVAudioPlayer(contentsOf: URL(filePath: "/System/Library/Sounds/Submarine.aiff"))
    player.numberOfLoops = -1
    player.volume = 0.3
    player.play()
    defer { player.stop() }
    try? await Task.sleep(for: .seconds(1))
    _ = try await capture.start(pressedAt: HostTime.now())
    try? await Task.sleep(for: .seconds(1))
    _ = try await capture.stop(releasedAt: HostTime.now())
    let since = Date()
    await capture.selectDevice(uid: builtIn)
    try? await Task.sleep(for: .seconds(1))
    let pressed = HostTime.now()
    let started = try await capture.start(pressedAt: pressed)
    let pressToMicMs = started.micRunningAt.milliseconds(since: pressed)
    try? await Task.sleep(for: .seconds(1))
    let recording = try await capture.stop(releasedAt: HostTime.now())
    let keptMs = recording.keptDuration / .milliseconds(1)
    let firstMs = recording.firstSampleOffset.map { $0 / .milliseconds(1) }
    let log = try captureLog(since: since)
    return ScenarioResult(
      scenario: name, passed: pressToMicMs < 200 && keptMs > 800,
      detail:
        "engine running \(String(format: "%.0f", pressToMicMs)) ms after the press, first sample \(firstMs.map { String(format: "%.0f", $0) } ?? "none") ms, warm \(started.wasWarm), recording kept \(String(format: "%.0f", keptMs)) ms of 1000; log: "
        + log.joined(separator: " | "),
      keptMs: keptMs)
  } catch {
    return ScenarioResult(scenario: name, passed: false, detail: "\(error)")
  }
}

private func captureLog(since date: Date) throws -> [String] {
  let store = try OSLogStore(scope: .currentProcessIdentifier)
  return try store.getEntries(at: store.position(date: date))
    .compactMap { $0 as? OSLogEntryLog }
    .filter { $0.subsystem == "com.openvocally.app" && $0.category == "capture" }
    .map(\.composedMessage)
}

func deviceChangeScenario(_ number: Int) async -> ScenarioResult? {
  switch number {
  case 1: await unplugDuringRecording()
  case 2: await plugInWhileWarm()
  case 3: await plugInDuringRecording()
  case 4: await bluetoothProfileSwitch()
  case 5: await switchFromBluetoothToBuiltIn()
  default: nil
  }
}
