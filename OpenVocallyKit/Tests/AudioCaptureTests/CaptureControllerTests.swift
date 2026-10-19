import AVFoundation
import DictationCore
import Testing

@testable import AudioCapture

struct CaptureControllerTests {
  let release = press.advanced(by: .seconds(2))
  let interruptions = Interruptions()

  func controller(_ fake: FakeHardware, watchdog: Duration = .seconds(30)) -> CaptureController {
    CaptureController(
      warmDuration: .zero, watchdog: watchdog, hardware: fake.hardware,
      levels: AsyncStream<AudioLevels>.makeStream().continuation, onSourceStopped: { _ in })
  }

  @Test func `a press then a release returns the recording`() async throws {
    let controller = controller(FakeHardware())

    let started = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    let recording = try await controller.stop(releasedAt: release)

    #expect(started.wasWarm == false)
    #expect(started.micRunningAt == press)
    #expect(recording.samples == FakeRecorder.samples)
  }

  @Test func `a cancel drops the recording and releases the mic`() async throws {
    let controller = controller(FakeHardware())
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)

    await controller.cancel()

    await #expect(throws: CaptureError.notRecording) { try await controller.stop(releasedAt: release) }
    let next = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    #expect(next.wasWarm == false)
  }

  @Test func `a cancel while the mic is starting cancels the press`() async throws {
    let gate = Gate()
    let recorder = FakeRecorder(start: gate)
    let controller = controller(FakeHardware(recorders: [recorder]))
    let start = Task { try await controller.start(pressedAt: press, onInterrupted: interruptions.handler) }
    await gate.arrived()

    let cancel = Task { await controller.cancel() }
    await recorder.arrival(of: "stopMic")
    gate.open()

    await #expect(throws: CaptureError.cancelled) { try await start.value }
    await cancel.value
    await #expect(throws: CaptureError.notRecording) { try await controller.stop(releasedAt: release) }
    let next = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    #expect(next.wasWarm == false)
  }

  @Test func `a release while the mic is starting cancels the press and keeps its audio`() async throws {
    let gate = Gate()
    let recorder = FakeRecorder(start: gate)
    let controller = controller(FakeHardware(recorders: [recorder]))
    let start = Task { try await controller.start(pressedAt: press, onInterrupted: interruptions.handler) }
    await gate.arrived()

    let stop = Task { try await controller.stop(releasedAt: release) }
    await recorder.arrival(of: "finishRecording")
    gate.open()

    await #expect(throws: CaptureError.cancelled) { try await start.value }
    #expect(try await stop.value.samples == FakeRecorder.samples)
  }

  @Test func `a release during the permission prompt cancels the press before the mic opens`() async {
    let prompt = Gate()
    let fake = FakeHardware(permission: .notDetermined, permissionPrompt: prompt)
    let controller = controller(fake)
    let start = Task { try await controller.start(pressedAt: press, onInterrupted: interruptions.handler) }
    await prompt.arrived()

    await #expect(throws: CaptureError.notRecording) { try await controller.stop(releasedAt: release) }
    prompt.open()

    await #expect(throws: CaptureError.cancelled) { try await start.value }
    #expect(fake.made.isEmpty)
  }

  @Test func `a denied permission fails the press`() async {
    let fake = FakeHardware(permission: .denied)
    let controller = controller(fake)

    await #expect(throws: CaptureError.microphonePermissionDenied) {
      try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    }
    #expect(fake.made.isEmpty)
  }

  @Test func `a device lost while recording reports deviceLost and ends the recording`() async throws {
    let fake = FakeHardware()
    let controller = controller(fake)
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)

    fake.devices = []
    await controller.devicesChanged()

    #expect(interruptions.reported == [.deviceLost])
    await #expect(throws: CaptureError.notRecording) { try await controller.stop(releasedAt: release) }
  }

  @Test func `a device lost while the mic is starting fails the start with deviceLost`() async {
    let gate = Gate()
    let fake = FakeHardware(recorders: [FakeRecorder(start: gate)])
    let controller = controller(fake)
    let start = Task { try await controller.start(pressedAt: press, onInterrupted: interruptions.handler) }
    await gate.arrived()

    fake.devices = []
    await controller.devicesChanged()
    gate.open()

    await #expect(throws: CaptureError.deviceLost) { try await start.value }
    #expect(interruptions.reported == [])
  }

  @Test func `a hung start times out and the next press records on a fresh recorder`() async throws {
    let hung = Gate()
    let fake = FakeHardware(recorders: [FakeRecorder(start: hung)])
    let controller = controller(fake, watchdog: .milliseconds(250))

    await #expect(throws: CaptureError.startTimedOut) {
      try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    }
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    let recording = try await controller.stop(releasedAt: release)

    #expect(recording.samples == FakeRecorder.samples)
    #expect(fake.made.count == 2)
    hung.open()
  }

  @Test func `a hung stop times out and the next press records on a fresh recorder`() async throws {
    let hung = Gate()
    let fake = FakeHardware(recorders: [FakeRecorder(finish: hung)])
    let controller = controller(fake, watchdog: .milliseconds(250))
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)

    await #expect(throws: CaptureError.stopTimedOut) { try await controller.stop(releasedAt: release) }
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)
    let recording = try await controller.stop(releasedAt: release)

    #expect(recording.samples == FakeRecorder.samples)
    #expect(fake.made.count == 2)
    hung.open()
  }

  @Test func `a stopped capture session restarts and the recording continues`() async throws {
    let recorder = FakeRecorder()
    let controller = controller(FakeHardware(recorders: [recorder]))
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)

    await recorder.sessionStops()
    await controller.sourceStopped(ObjectIdentifier(recorder))

    #expect(await recorder.isRunning)
    #expect(try await controller.stop(releasedAt: release).samples == FakeRecorder.samples)
    #expect(interruptions.reported == [])
  }

  @Test func `a capture session that cannot restart reports captureFailed`() async throws {
    let recorder = FakeRecorder(restartFails: true)
    let controller = controller(FakeHardware(recorders: [recorder]))
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)

    await recorder.sessionStops()
    await controller.sourceStopped(ObjectIdentifier(recorder))

    #expect(interruptions.reported == [.captureFailed])
    await #expect(throws: CaptureError.notRecording) { try await controller.stop(releasedAt: release) }
  }

  @Test func `a capture session stopped by its device vanishing reports deviceLost`() async throws {
    let recorder = FakeRecorder()
    let fake = FakeHardware(recorders: [recorder])
    let controller = controller(fake)
    _ = try await controller.start(pressedAt: press, onInterrupted: interruptions.handler)

    fake.devices = []
    await recorder.sessionStops()
    await controller.sourceStopped(ObjectIdentifier(recorder))

    #expect(interruptions.reported == [.deviceLost])
    await #expect(throws: CaptureError.notRecording) { try await controller.stop(releasedAt: release) }
  }
}
