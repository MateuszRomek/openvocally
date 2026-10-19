import AVFoundation
import DictationCore
import Synchronization
import os

public enum CaptureError: Error, Equatable, Sendable {
  case microphonePermissionDenied
  case noInputDevice
  case startTimedOut
  case stopTimedOut
  case deviceLost
  case captureFailed
  case notRecording
  case alreadyRecording
  case cancelled
}

public struct CaptureStart: Sendable {
  public let wasWarm: Bool
  public let micRunningAt: HostTime
}

/// Captures 16 kHz mono audio from the press on. Every recorder call runs under a watchdog;
/// a call that hangs abandons that recorder and the next call builds a fresh one.
public final class AudioCapture: Sendable {
  private let controller: CaptureController
  /// Meter readings every 50 ms while recording. Only the newest reading is buffered.
  public let levels: AsyncStream<AudioLevels>
  /// The usable input devices now and after every device change, for one consumer. Only the
  /// newest list is buffered.
  public let microphones: AsyncStream<MicrophoneList>

  /// The mic closes at stop by default, so the privacy indicator goes off with the recording;
  /// a cold start costs about 45 ms to the first sample on the built-in mic.
  public init(warmDuration: Duration = .zero, watchdog: Duration = .seconds(5)) {
    // Handlers recompute from the current device list, so a burst collapses to one event.
    let (devices, devicesContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (configurations, configurationsContinuation) = AsyncStream<ObjectIdentifier>.makeStream()
    let (levels, levelsContinuation) = AsyncStream<AudioLevels>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    self.levels = levels
    let (microphones, microphonesContinuation) = AsyncStream<MicrophoneList>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    self.microphones = microphones
    let controller = CaptureController(
      warmDuration: warmDuration, watchdog: watchdog, levels: levelsContinuation,
      onSourceStopped: { configurationsContinuation.yield($0) })
    self.controller = controller
    DeviceMonitor.start(devicesContinuation)
    Task {
      microphonesContinuation.yield(CoreAudioDevices.microphones())
      for await _ in devices {
        await controller.devicesChanged()
        microphonesContinuation.yield(CoreAudioDevices.microphones())
      }
    }
    Task {
      for await recorder in configurations { await controller.sourceStopped(recorder) }
    }
  }

  /// Picks the device, then builds and prepares the recorder. Call before the first press.
  public func prepare(deviceUID: String?) async throws(CaptureError) {
    try await controller.prepare(deviceUID: deviceUID)
  }

  /// Switches to the device the user picked, or the system default for `nil`. A
  /// recording in progress keeps its device; the switch happens when it ends.
  public func selectDevice(uid: String?) async {
    await controller.select(deviceUID: uid)
  }

  /// Throws `cancelled` when `stop` or `cancel` arrives before the recorder runs, the
  /// interruption error when the device fails before the recorder runs, and `alreadyRecording`
  /// while an earlier press or its stop is still in flight.
  /// `onInterrupted` fires at most once, only when this recording fails after the start returned.
  public func start(
    pressedAt press: HostTime, onInterrupted: @escaping @Sendable (CaptureError) -> Void = { _ in }
  ) async throws(CaptureError) -> CaptureStart {
    try await controller.start(pressedAt: press, onInterrupted: onInterrupted)
  }

  /// Returns the audio from the press to `release`, the host time of the key release.
  public func stop(releasedAt release: HostTime) async throws(CaptureError) -> Recording {
    try await controller.stop(releasedAt: release)
  }

  /// Drops the samples and releases the mic like a failure.
  public func cancel() async {
    await controller.cancel()
  }

  /// The recording so far at 16 kHz, nil when nothing records. Every sample matches the one at
  /// the same index in the recording `stop` returns.
  @concurrent
  public func recordingSoFar() async -> [Float]? {
    guard let raw = await controller.soFar() else { return nil }
    return SpeechResampler.settledPrefix(raw.samples[...], from: raw.rate)
  }
}
