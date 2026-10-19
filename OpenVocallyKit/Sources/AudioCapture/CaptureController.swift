import AVFoundation
import DictationCore
import Synchronization
import os

/// One recording, from the press until its stop, cancel, interruption or failed start.
private struct ActiveRecording {
  let token: UInt64
  /// Set once the start returned; cleared when the stop begins.
  var handler: (@Sendable (CaptureError) -> Void)?
  var meter: Task<Void, Never>?
  /// Set when the device failed before the start returned or during the stop.
  var interruption: CaptureError?
}

enum CaptureLimits {
  /// A Bluetooth headset switches profiles when its mic opens, which took up to 6.1 s on
  /// AirPods Pro, so its calls get longer before they count as hung.
  static func watchdog(base: Duration, transport: Microphone.Transport?) -> Duration {
    transport == .bluetooth ? max(base, .seconds(10)) : base
  }

  /// A running capture holds a Bluetooth headset in its narrower headset profile, so music
  /// sounds worse until the mic closes; the capture session cold-starts in about 55 to 140 ms
  /// on AirPods, so a short window is enough to cover quick follow-ups.
  static func warm(base: Duration, transport: Microphone.Transport?) -> Duration {
    transport == .bluetooth ? min(base, .seconds(5)) : base
  }
}

actor CaptureController {
  private let watchdog: Duration
  private let warmDuration: Duration
  private let hardware: CaptureHardware
  private var lifecycle = MicLifecycle()
  private var recorder: (any CaptureRecorder)?
  private var device: InputDevice?
  private var savedUID: String?
  private var permissionRequested = false
  private var pendingPress: UInt64?
  private var pressCount: UInt64 = 0
  private var warmTimer: Task<Void, Never>?
  private var active: ActiveRecording?
  private let onSourceStopped: @Sendable (ObjectIdentifier) -> Void
  private let levels: AsyncStream<AudioLevels>.Continuation

  init(
    warmDuration: Duration, watchdog: Duration, hardware: CaptureHardware = .live,
    levels: AsyncStream<AudioLevels>.Continuation,
    onSourceStopped: @escaping @Sendable (ObjectIdentifier) -> Void
  ) {
    self.warmDuration = warmDuration
    self.watchdog = watchdog
    self.hardware = hardware
    self.levels = levels
    self.onSourceStopped = onSourceStopped
  }

  private var isBusy: Bool {
    pendingPress != nil || active != nil || lifecycle.isRecording
  }

  private func startMeter(_ sink: FrameSink, token: UInt64) {
    guard active?.token == token else { return }
    let levels = levels
    active?.meter?.cancel()
    active?.meter = Task { await Self.runMeter(sink, levels) }
  }

  /// The one exit for a recording. Ignores a token that is no longer the active one.
  private func endActive(_ token: UInt64? = nil) {
    guard let current = active, token == nil || current.token == token else { return }
    current.meter?.cancel()
    active = nil
  }

  @concurrent private static func runMeter(
    _ sink: FrameSink, _ levels: AsyncStream<AudioLevels>.Continuation
  ) async {
    var meter = LevelMeter()
    var buffer = [Float](repeating: 0, count: LevelMeter.fftSize)
    let started = ContinuousClock.now
    while !Task.isCancelled {
      if let rate = sink.latest(into: &buffer) {
        levels.yield(meter.analyze(samples: buffer, sampleRate: rate, elapsed: .now - started))
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  /// Synchronous, so the change loop never waits on a recorder whose device may be gone.
  func devicesChanged() {
    let devices = hardware.inputDevices()
    let selected = InputDevicePolicy.select(
      saved: savedUID, systemDefault: hardware.defaultInputUID(), devices: devices)
    switch DeviceChangeAction.decide(recording: isBusy, active: device, selected: selected, devices: devices)
    {
    case .none:
      return
    case .interrupt:
      captureLogger.notice("Input device vanished while recording")
      interrupt(.deviceLost)
    case .reselect:
      reconcile()
    }
  }

  /// The capture session reports a runtime error, an interruption, a stop or a disconnected
  /// device. On a device that is still there, one restart keeps the recording going; the audio
  /// gap during the restart stays in the recording as-is.
  func sourceStopped(_ id: ObjectIdentifier) async {
    guard let recorder, ObjectIdentifier(recorder) == id, let token = active?.token,
      active?.interruption == nil, lifecycle.isRecording
    else { return }
    let running = await withDeadline(watchdog) { await recorder.isRunning }
    guard isCurrent(recorder, token), running != true else { return }
    captureLogger.notice("Capture session stopped during a recording")
    guard let device, DeviceChangeAction.isPresent(device, in: hardware.inputDevices()) else {
      interrupt(.deviceLost)
      return
    }
    let restarted =
      (try? await withDeadline(watchdog) { () throws(CaptureError) in try await recorder.restart() }) != nil
    guard isCurrent(recorder, token) else { return }
    if !restarted { interrupt(.captureFailed) }
  }

  private func isCurrent(_ recorder: any CaptureRecorder, _ token: UInt64) -> Bool {
    self.recorder === recorder && active?.token == token && active?.interruption == nil
  }

  /// Ends the current recording from outside the press and release. Drops the recorder, whose
  /// device may be gone, without waiting on it. Reports through the handler only after the
  /// start returned; before that the start throws the error, and during a stop the stop does.
  private func interrupt(_ error: CaptureError) {
    pendingPress = nil
    guard var current = active, current.interruption == nil else {
      dropRecorder()
      scheduleReprepare()
      return
    }
    current.meter?.cancel()
    current.meter = nil
    current.interruption = error
    let handler = current.handler
    current.handler = nil
    active = current
    dropRecorder()
    guard let handler else { return }
    endActive(current.token)
    scheduleReprepare()
    handler(error)
  }

  /// Runs after every recording exit. Releases the mic and re-prepares in the background when
  /// the active device is gone or another one would be picked now.
  @discardableResult private func reconcile() -> Bool {
    guard pendingPress == nil, active == nil else { return false }
    let devices = hardware.inputDevices()
    let selected = InputDevicePolicy.select(
      saved: savedUID, systemDefault: hardware.defaultInputUID(), devices: devices)
    guard
      DeviceChangeAction.decide(recording: false, active: device, selected: selected, devices: devices)
        == .reselect
    else { return false }
    dropRecorder()
    scheduleReprepare()
    return true
  }

  /// Forgets the device and the recorder before anything awaits, then shuts the old recorder
  /// down in the background under the watchdog: a call on a vanished device can hang.
  private func dropRecorder() {
    _ = lifecycle.release()
    warmTimer?.cancel()
    warmTimer = nil
    device = nil
    guard let recorder else { return }
    self.recorder = nil
    let watchdog = watchdog
    Task {
      _ = await withDeadline(watchdog) { await recorder.shutdown() }
    }
  }

  private func scheduleReprepare() {
    Task { await self.reprepare() }
  }

  private func reprepare() async {
    guard hardware.permission() == .authorized, !isBusy else { return }
    do throws(CaptureError) {
      try await prepare(deviceUID: savedUID)
    } catch {
      guard error != .alreadyRecording else { return }
      captureLogger.notice(
        "Re-preparing after a device change failed: \(String(describing: error), privacy: .public)")
    }
  }

  func select(deviceUID: String?) {
    guard deviceUID != savedUID else { return }
    savedUID = deviceUID
    if recorder == nil {
      scheduleReprepare()
    } else {
      reconcile()
    }
  }

  func prepare(deviceUID: String?) async throws(CaptureError) {
    savedUID = deviceUID
    try await ensurePermission()
    let selected = try selectDevice()
    guard !isBusy else { throw .alreadyRecording }
    let changed = selected != device
    device = selected
    if changed, recorder != nil {
      await perform(lifecycle.release(), discarding: true)
      guard !isBusy else { return }
    }
    let recorder = currentRecorder()
    try await guarded(recorder, timeout: .startTimedOut) { () throws(CaptureError) in
      try await recorder.prepare(device: selected)
    }
  }

  func start(
    pressedAt press: HostTime, onInterrupted: @escaping @Sendable (CaptureError) -> Void
  ) async throws(CaptureError) -> CaptureStart {
    captureSignposter.emitEvent("press")
    guard !isBusy else { throw .alreadyRecording }
    pressCount += 1
    let token = pressCount
    pendingPress = token
    active = ActiveRecording(token: token)
    defer { if pendingPress == token { pendingPress = nil } }
    do {
      let started = try await startRecording(pressedAt: press, token: token)
      active?.handler = onInterrupted
      return started
    } catch {
      let interruption = active?.token == token ? active?.interruption : nil
      if pendingPress == token { pendingPress = nil }
      endActive(token)
      reconcile()
      throw interruption ?? error
    }
  }

  private func startRecording(pressedAt press: HostTime, token: UInt64) async throws(CaptureError)
    -> CaptureStart
  {
    try await ensurePermission()
    if device == nil { device = try selectDevice() }
    guard pendingPress == token else { throw .cancelled }
    warmTimer?.cancel()
    warmTimer = nil
    lifecycle.start()
    let interval = captureSignposter.beginInterval("micStart")
    defer { captureSignposter.endInterval("micStart", interval) }
    let recorder = currentRecorder()
    let device = device
    let started: MicStart
    do {
      started = try await guarded(recorder, timeout: .startTimedOut) { () throws(CaptureError) in
        try await recorder.start(pressedAt: press, device: device)
      }
    } catch {
      if self.recorder === recorder { self.device = nil }
      await releaseMic(ifStill: recorder)
      throw error
    }
    guard pendingPress == token else { throw .cancelled }
    startMeter(recorder.sink, token: token)
    return CaptureStart(wasWarm: !started.cold, micRunningAt: started.runningAt)
  }

  func stop(releasedAt release: HostTime) async throws(CaptureError) -> Recording {
    pendingPress = nil
    active?.handler = nil
    active?.meter?.cancel()
    guard let token = active?.token else { throw .notRecording }
    if let interruption = active?.interruption {
      endActive(token)
      reconcile()
      throw interruption
    }
    guard lifecycle.isRecording, let recorder else {
      endActive(token)
      reconcile()
      throw .notRecording
    }
    let recording: Recording
    do {
      recording = try await guarded(recorder, timeout: .stopTimedOut) { () throws(CaptureError) in
        try await recorder.finishRecording(releasedAt: release)
      }
    } catch {
      let interruption = active?.token == token ? active?.interruption : nil
      endActive(token)
      if interruption == nil { await releaseMic(ifStill: recorder) }
      reconcile()
      throw interruption ?? error
    }
    let interrupted = active?.token == token && active?.interruption != nil
    endActive(token)
    // An interruption already released the mic; a changed selection releases it here.
    if reconcile() || interrupted || self.recorder !== recorder { return recording }
    let warm = CaptureLimits.warm(base: warmDuration, transport: device?.transport)
    switch lifecycle.stop(now: .now, warm: warm) {
    case .stopMic:
      // Stopping a USB device took up to 280 ms; the release must not wait for it.
      Task { await perform(.stopMic, discarding: false) }
    case let action:
      await perform(action, discarding: false)
    }
    return recording
  }

  func soFar() -> (samples: [Float], rate: Double)? {
    guard active != nil else { return nil }
    return recorder?.sink.soFar()
  }

  func cancel() async {
    pendingPress = nil
    endActive()
    guard !reconcile() else { return }
    await perform(lifecycle.release(), discarding: true)
  }

  private func releaseMic(ifStill recorder: any CaptureRecorder) async {
    guard self.recorder === recorder else { return }
    await perform(lifecycle.release(), discarding: true)
  }

  private func warmExpired() async {
    await perform(lifecycle.warmExpired(now: .now), discarding: false)
  }

  private func perform(_ action: MicLifecycle.Action, discarding: Bool) async {
    switch action {
    case .none:
      return
    case .keepWarm(let until):
      warmTimer?.cancel()
      warmTimer = Task { [weak self] in
        try? await Task.sleep(until: until, clock: .continuous)
        guard !Task.isCancelled else { return }
        await self?.warmExpired()
      }
    case .stopMic:
      warmTimer?.cancel()
      warmTimer = nil
      guard let recorder else { return }
      do {
        try await guarded(recorder, timeout: .stopTimedOut) { () throws(CaptureError) in
          await recorder.stopMic(discardingRecording: discarding)
        }
      } catch {
        captureLogger.error("Mic stop failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  private func currentRecorder() -> any CaptureRecorder {
    if let recorder { return recorder }
    let fresh = hardware.makeRecorder(onSourceStopped)
    recorder = fresh
    return fresh
  }

  private func guarded<T: Sendable>(
    _ recorder: any CaptureRecorder, timeout: CaptureError,
    _ operation: sending @escaping @isolated(any) () async throws(CaptureError) -> T
  ) async throws(CaptureError) -> T {
    let limit = CaptureLimits.watchdog(base: watchdog, transport: device?.transport)
    if let value = try await withDeadline(limit, operation) { return value }
    captureLogger.error("Capture call timed out; abandoning the recorder")
    if self.recorder === recorder {
      self.recorder = nil
      _ = lifecycle.release()
      warmTimer?.cancel()
      warmTimer = nil
    }
    throw timeout
  }

  private func ensurePermission() async throws(CaptureError) {
    switch hardware.permission() {
    case .authorized:
      return
    case .notDetermined where !permissionRequested:
      permissionRequested = true
      guard await hardware.requestPermission() else { throw .microphonePermissionDenied }
    default:
      throw .microphonePermissionDenied
    }
  }

  private func selectDevice() throws(CaptureError) -> InputDevice {
    let devices = hardware.inputDevices()
    guard
      let selected = InputDevicePolicy.select(
        saved: savedUID, systemDefault: hardware.defaultInputUID(), devices: devices)
    else {
      captureLogger.error("No usable input device")
      throw .noInputDevice
    }
    if let savedUID, savedUID != selected.uid {
      captureLogger.notice("Saved input device unavailable: \(savedUID, privacy: .private)")
    }
    return selected
  }
}
