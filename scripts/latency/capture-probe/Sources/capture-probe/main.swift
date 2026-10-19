import AudioCapture
import CoreAudio
import DictationCore
import Foundation

struct Options {
  var device: String?
  var runs = 20
  var warm = false
  var idleMilliseconds = 1_500
  var holdMilliseconds = 500
  var pressLeadMilliseconds = 0
  var out = "/dev/stdout"
  var checkIdle = false
  var deviceChange: [Int] = []

  init(_ arguments: [String]) throws {
    var iterator = arguments.dropFirst().makeIterator()
    while let flag = iterator.next() {
      if flag == "--check-idle" {
        checkIdle = true
        continue
      }
      guard let value = iterator.next() else { throw ProbeError.usage("missing value for \(flag)") }
      switch flag {
      case "--device": device = value == "default" ? nil : value
      case "--runs": runs = try Self.integer(value, flag)
      case "--mode":
        guard ["cold", "warm"].contains(value) else { throw ProbeError.usage("--mode is cold or warm") }
        warm = value == "warm"
      case "--idle": idleMilliseconds = try Self.integer(value, flag)
      case "--hold": holdMilliseconds = try Self.integer(value, flag)
      case "--press-lead": pressLeadMilliseconds = try Self.integer(value, flag)
      case "--device-change":
        deviceChange = try value.split(separator: ",").map { try Self.integer(String($0), flag) }
      case "--out": out = value
      default: throw ProbeError.usage("unknown flag \(flag)")
      }
    }
  }

  private static func integer(_ value: String, _ flag: String) throws -> Int {
    guard let number = Int(value), number >= 0 else { throw ProbeError.usage("\(flag) takes a whole number") }
    return number
  }
}

enum ProbeError: Error {
  case usage(String)
  case setup(String)
}

struct Run: Encodable {
  let run: Int
  let mode: String
  let wasWarm: Bool
  let pressToEngineRunningMs: Double
  let pressToFirstSampleMs: Double?
  let samples: Int
  let holdMs: Double
  let keptMs: Double
  let releaseToStopReturnedMs: Double
}

struct IdleCheck: Encodable {
  let deviceRunningSomewhereWhileRecording: Bool?
  let deviceRunningSomewhereAfterStop: Bool?
}

func deviceRunningSomewhere(uid: String?) -> Bool? {
  var id = AudioDeviceID(0)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  if let uid {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier,
        &size, &id)
    }
    guard status == noErr else { return nil }
  } else {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        == noErr
    else { return nil }
  }
  var running: UInt32 = 0
  var runningSize = UInt32(MemoryLayout<UInt32>.size)
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  guard id != 0, AudioObjectGetPropertyData(id, &address, 0, nil, &runningSize, &running) == noErr else {
    return nil
  }
  return running != 0
}

struct RunError: Encodable {
  let run: Int
  let error: String
}

let output: FileHandle
let options: Options
do {
  options = try Options(CommandLine.arguments)
  FileManager.default.createFile(atPath: options.out, contents: nil)
  guard let handle = FileHandle(forWritingAtPath: options.out) else {
    throw ProbeError.usage("cannot write \(options.out)")
  }
  output = handle
} catch {
  FileHandle.standardError.write(Data("capture-probe: \(error)\n".utf8))
  exit(64)
}

let encoder = JSONEncoder()
encoder.outputFormatting = .sortedKeys
func emit(_ value: some Encodable) {
  guard let line = try? encoder.encode(value) else { return }
  output.write(line + Data("\n".utf8))
}

if !options.deviceChange.isEmpty {
  var passed = true
  for number in options.deviceChange {
    guard let result = await deviceChangeScenario(number) else {
      emit(RunError(run: -1, error: "no device-change case \(number)"))
      exit(64)
    }
    emit(result)
    passed = passed && result.passed
  }
  exit(passed ? 0 : 1)
}

let capture = AudioCapture(warmDuration: options.warm ? .seconds(15) : .zero)
var failed = false
do {
  try await capture.prepare(deviceUID: options.device)
} catch {
  emit(RunError(run: -1, error: "prepare: \(error)"))
  exit(1)
}

if options.checkIdle {
  do {
    _ = try await capture.start(pressedAt: HostTime.now())
    try? await Task.sleep(for: .milliseconds(300))
    let during = deviceRunningSomewhere(uid: options.device)
    _ = try await capture.stop(releasedAt: HostTime.now())
    try? await Task.sleep(for: .milliseconds(1_000))
    emit(
      IdleCheck(
        deviceRunningSomewhereWhileRecording: during,
        deviceRunningSomewhereAfterStop: deviceRunningSomewhere(uid: options.device)))
    exit(0)
  } catch {
    emit(RunError(run: -1, error: "check-idle: \(error)"))
    exit(1)
  }
}

for index in 0..<options.runs {
  try? await Task.sleep(for: .milliseconds(options.idleMilliseconds))
  let press = HostTime.now().advanced(by: .zero - .milliseconds(options.pressLeadMilliseconds))
  do {
    let started = try await capture.start(pressedAt: press)
    try? await Task.sleep(for: .milliseconds(options.holdMilliseconds))
    let release = HostTime.now()
    let recording = try await capture.stop(releasedAt: release)
    let returned = HostTime.now()
    emit(
      Run(
        run: index,
        mode: options.warm ? "warm" : "cold",
        wasWarm: started.wasWarm,
        pressToEngineRunningMs: started.micRunningAt.milliseconds(since: press),
        pressToFirstSampleMs: recording.firstSampleOffset.map { $0 / .milliseconds(1) },
        samples: recording.samples.count,
        holdMs: release.milliseconds(since: press),
        keptMs: recording.keptDuration / .milliseconds(1),
        releaseToStopReturnedMs: returned.milliseconds(since: release)
      ))
  } catch {
    failed = true
    emit(RunError(run: index, error: "\(error)"))
  }
}
exit(failed ? 1 : 0)
