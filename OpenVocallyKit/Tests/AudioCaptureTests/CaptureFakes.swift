import AVFoundation
import DictationCore
import Synchronization

@testable import AudioCapture

/// Holds every caller until the test opens it, like a hardware call that blocks, and tells the
/// test when a caller arrived. Ignores cancellation, as a blocked capture session call does.
final class Gate: Sendable {
  private struct State {
    var isOpen = false
    var arrivals = 0
    var held: [CheckedContinuation<Void, Never>] = []
    var watchers: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  func pass() async {
    await withCheckedContinuation { caller in
      let (resumeNow, watchers) = state.withLock { state in
        state.arrivals += 1
        defer { state.watchers = [] }
        if !state.isOpen { state.held.append(caller) }
        return (state.isOpen, state.watchers)
      }
      for watcher in watchers { watcher.resume() }
      if resumeNow { caller.resume() }
    }
  }

  /// Returns once a caller reached the gate.
  func arrived() async {
    await withCheckedContinuation { watcher in
      let now = state.withLock { state in
        if state.arrivals == 0 { state.watchers.append(watcher) }
        return state.arrivals > 0
      }
      if now { watcher.resume() }
    }
  }

  func open() {
    let held = state.withLock { state in
      state.isOpen = true
      defer { state.held = [] }
      return state.held
    }
    for caller in held { caller.resume() }
  }
}

/// Stands in for `Recorder`. Runs its calls one at a time in arrival order, as the recorder's
/// serial queue does, so a call held at a gate holds back the calls behind it.
actor FakeRecorder: CaptureRecorder {
  static let samples: [Float] = [0.25, 0.5, 0.75]

  nonisolated let sink = FrameSink()
  private(set) var isRunning = false
  private var isRecording = false
  private var busy = false
  private var queue: [CheckedContinuation<Void, Never>] = []
  private var arrivals: [String] = []
  private var watchers: [(call: String, waiter: CheckedContinuation<Void, Never>)] = []
  private let startGate: Gate?
  private let finishGate: Gate?
  private let restartFails: Bool

  init(start: Gate? = nil, finish: Gate? = nil, restartFails: Bool = false) {
    startGate = start
    finishGate = finish
    self.restartFails = restartFails
  }

  /// Returns once `call` reached the recorder, even if it still waits behind another call.
  func arrival(of call: String) async {
    guard !arrivals.contains(call) else { return }
    await withCheckedContinuation { watchers.append((call, $0)) }
  }

  /// The system stops the capture session, as a route change or a disconnect does.
  func sessionStops() {
    isRunning = false
  }

  func prepare(device: InputDevice?) async throws(CaptureError) {
    await enter("prepare")
    defer { leave() }
    guard device != nil else { throw .noInputDevice }
  }

  func start(pressedAt press: HostTime, device: InputDevice?) async throws(CaptureError) -> MicStart {
    await enter("start")
    defer { leave() }
    await startGate?.pass()
    let cold = !isRunning
    isRunning = true
    isRecording = true
    return MicStart(runningAt: press, cold: cold)
  }

  func restart() async throws(CaptureError) {
    await enter("restart")
    defer { leave() }
    guard isRecording else { throw .notRecording }
    if restartFails { throw .captureFailed }
    isRunning = true
  }

  func finishRecording(releasedAt release: HostTime) async throws(CaptureError) -> Recording {
    await enter("finishRecording")
    defer { leave() }
    await finishGate?.pass()
    guard isRecording else { throw .notRecording }
    isRecording = false
    return Recording(samples: Self.samples, firstSampleOffset: .zero, keptDuration: .milliseconds(1))
  }

  func stopMic(discardingRecording: Bool) async {
    await enter("stopMic")
    defer { leave() }
    if discardingRecording { isRecording = false }
    guard !isRecording else { return }
    isRunning = false
  }

  func shutdown() async {
    await enter("shutdown")
    defer { leave() }
    isRecording = false
    isRunning = false
  }

  private func enter(_ call: String) async {
    arrivals.append(call)
    let ready = watchers.filter { $0.call == call }
    watchers.removeAll { $0.call == call }
    for watcher in ready { watcher.waiter.resume() }
    if busy { await withCheckedContinuation { queue.append($0) } }
    busy = true
  }

  /// Hands the recorder to the next call in line, which keeps it busy.
  private func leave() {
    if queue.isEmpty {
      busy = false
    } else {
      queue.removeFirst().resume()
    }
  }
}

/// The devices, permission and recorders a test hands the controller.
final class FakeHardware: Sendable {
  static let builtIn = InputDevice(
    uid: "built-in", id: 1, isAlive: true, hasInput: true, isAggregateOrVirtual: false, transport: .builtIn)

  private struct State {
    var devices = [FakeHardware.builtIn]
    var permission = AVAuthorizationStatus.authorized
    var queued: [FakeRecorder] = []
    var made: [FakeRecorder] = []
  }

  private let state = Mutex(State())
  private let permissionPrompt: Gate?

  /// With a `permissionPrompt`, the request waits at it, then grants access.
  init(
    recorders: [FakeRecorder] = [], permission: AVAuthorizationStatus = .authorized,
    permissionPrompt: Gate? = nil
  ) {
    state.withLock {
      $0.queued = recorders
      $0.permission = permission
    }
    self.permissionPrompt = permissionPrompt
  }

  var devices: [InputDevice] {
    get { state.withLock { $0.devices } }
    set { state.withLock { $0.devices = newValue } }
  }

  /// Every recorder the controller built, in order.
  var made: [FakeRecorder] { state.withLock { $0.made } }

  var hardware: CaptureHardware {
    CaptureHardware(
      inputDevices: { self.devices },
      defaultInputUID: { self.state.withLock { $0.devices.first?.uid } },
      permission: { self.state.withLock { $0.permission } },
      requestPermission: {
        await self.permissionPrompt?.pass()
        self.state.withLock { $0.permission = .authorized }
        return true
      },
      makeRecorder: { _ in
        self.state.withLock { state in
          let recorder = state.queued.isEmpty ? FakeRecorder() : state.queued.removeFirst()
          state.made.append(recorder)
          return recorder
        }
      })
  }
}

/// Records the errors `onInterrupted` reports, in order.
final class Interruptions: Sendable {
  private let errors = Mutex<[CaptureError]>([])

  var reported: [CaptureError] { errors.withLock { $0 } }

  var handler: @Sendable (CaptureError) -> Void {
    { error in self.errors.withLock { $0.append(error) } }
  }
}
