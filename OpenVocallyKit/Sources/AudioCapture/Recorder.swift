import AVFoundation
import AudioToolbox
import DictationCore
import Synchronization
import os

let captureLogger = Logger(subsystem: "com.openvocally.app", category: "capture")
let captureSignposter = OSSignposter(subsystem: "com.openvocally.app", category: "capture")
let latencySignposter = OSSignposter(subsystem: "com.openvocally.app", category: "latency")

/// Shared by the recorder actor and the real-time IO thread. The actor holds the lock only to
/// swap the frames in or out, so the IO thread never waits long and never frees memory.
final class FrameSink: Sendable {
  private let state = Mutex<RawFrames?>(nil)

  func begin(_ frames: consuming RawFrames) {
    var next: RawFrames? = consume frames
    state.withLock { swap(&$0, &next) }
  }

  var isRecording: Bool {
    state.withLock { $0 != nil }
  }

  func covers(_ instant: HostTime) -> Bool? {
    state.withLock { frames in
      guard let frames else { return nil }
      return frames.coveredUntil.map { $0 >= instant } ?? false
    }
  }

  /// Copies the newest samples into the end of `buffer` and zeroes the rest. Returns the
  /// sample rate, or nil when nothing is recording. The lock covers only the copy.
  func latest(into buffer: inout [Float]) -> Double? {
    let rate: Double? = buffer.withUnsafeMutableBufferPointer { destination in
      state.withLock { frames -> Double? in
        guard let frames else { return nil }
        frames.copyNewest(into: destination)
        return frames.sampleRate
      }
    }
    return rate
  }

  /// The kept samples so far and their rate. Allocates before taking the lock, which covers only
  /// the copy. Nil when the recording changed between the two.
  func soFar() -> (samples: [Float], rate: Double)? {
    guard
      let (press, available) = state.withLock({ frames in
        frames.map { ($0.press, $0.samples.count - min($0.keptStart, $0.samples.count)) }
      })
    else { return nil }
    var samples = [Float](repeating: 0, count: available)
    let copied = samples.withUnsafeMutableBufferPointer { destination in
      state.withLock { frames -> (count: Int, rate: Double)? in
        guard let frames, frames.press == press else { return nil }
        return (frames.copyKept(into: destination), frames.sampleRate)
      }
    }
    guard let copied else { return nil }
    samples.removeLast(samples.count - copied.count)
    return (samples, copied.rate)
  }

  func take() -> RawFrames? {
    state.withLock { $0.take() }
  }

  /// The one entry for every backend. `start` is the host time of the chunk's first frame; nil
  /// means now minus the chunk. A chunk at another rate than the recording's is dropped and
  /// counted, never converted here. Real-time safe: no allocation, logging or waits.
  func receive(list: UnsafePointer<AudioBufferList>, frames: Int, at start: HostTime?, rate: Double) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    state.withLock { recording in
      guard let sampleRate = recording?.sampleRate else { return }
      guard rate == sampleRate else {
        recording?.noteDropped()
        return
      }
      let start = start ?? HostTime.now().advanced(bySeconds: -Double(frames) / sampleRate)
      recording?.append(buffers, frames: frames, at: start)
    }
  }

  /// A chunk the source could not read, such as a non-contiguous block.
  func noteDropped() {
    state.withLock { $0?.noteDropped() }
  }
}

struct MicStart: Sendable {
  let runningAt: HostTime
  let cold: Bool
}

/// Owns one recording at a time and the capture session that fills it. Runs on its own
/// serial queue because session calls block; they must not hold a cooperative-pool thread or the
/// main actor.
actor Recorder {
  private let queue: DispatchSerialQueue
  nonisolated let sink = FrameSink()
  private var source: SessionSource?
  private var device: InputDevice?
  private var spare: RawFrames?
  private let onSourceStopped: @Sendable (ObjectIdentifier) -> Void

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(onSourceStopped: @escaping @Sendable (ObjectIdentifier) -> Void = { _ in }) {
    queue = DispatchSerialQueue(label: "com.openvocally.capture", qos: .userInteractive)
    self.onSourceStopped = onSourceStopped
  }

  var isRunning: Bool {
    source?.isRunning ?? false
  }

  /// Drops the recording and the source, for a device that vanished under it.
  func shutdown() {
    recycle(sink.take())
    teardown()
  }

  func prepare(device: InputDevice?) throws(CaptureError) {
    if source != nil, self.device == device { return }
    guard !sink.isRecording else { throw .alreadyRecording }
    teardown()
    let onSourceStopped = onSourceStopped
    let id = ObjectIdentifier(self)
    guard let device else { throw .noInputDevice }
    let source = try SessionSource(device: device, sink: sink, onStopped: { onSourceStopped(id) })
    self.source = source
    self.device = device
    spare = RawFrames(press: HostTime(ticks: 0), sampleRate: source.sampleRate)
  }

  func start(pressedAt press: HostTime, device: InputDevice?) throws(CaptureError) -> MicStart {
    try prepare(device: device)
    guard let source else { throw .captureFailed }
    let cold = !source.isRunning
    var frames =
      spare.take().flatMap { $0.sampleRate == source.sampleRate ? $0 : nil }
      ?? RawFrames(press: press, sampleRate: source.sampleRate)
    frames.reset(press: press)
    sink.begin(consume frames)
    if cold {
      do {
        try source.start()
      } catch {
        recycle(sink.take())
        throw error
      }
    }
    return MicStart(runningAt: HostTime.now(), cold: cold)
  }

  /// Restarts a recording source that the system stopped, keeping the same sink. Fails when the
  /// source cannot continue the same recording, such as a changed hardware rate.
  func restart() throws(CaptureError) {
    guard let source, sink.isRecording else { throw .notRecording }
    if source.isRunning { return }
    try source.restart()
  }

  func finishRecording(releasedAt release: HostTime) async throws(CaptureError) -> Recording {
    let deadline = release.advanced(by: .milliseconds(60))
    while true {
      guard let covered = sink.covers(release) else { throw .notRecording }
      if covered { break }
      if HostTime.now() >= deadline {
        captureLogger.notice("Captured audio did not reach the release within 60 ms")
        break
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
    let tailEnd = HostTime.now()
    let tailMs = tailEnd.milliseconds(since: release)
    latencySignposter.emitEvent("LB-02-tail", "ms=\(tailMs, format: .fixed(precision: 2), privacy: .public)")
    guard let frames = sink.take() else { throw .notRecording }
    let dropped = frames.droppedChunks
    let recording = frames.recording(releasedAt: release)
    let resampleMs = HostTime.now().milliseconds(since: tailEnd)
    latencySignposter.emitEvent(
      "LB-02-resample", "ms=\(resampleMs, format: .fixed(precision: 2), privacy: .public)")
    recycle(consume frames)
    guard let recording else {
      captureLogger.error("Resampling to 16 kHz failed")
      throw .captureFailed
    }
    let audioMs = Double(recording.samples.count) / 16.0
    latencySignposter.emitEvent(
      "LB-02-audio", "ms=\(audioMs, format: .fixed(precision: 2), privacy: .public)")
    guard dropped > 0 else { return recording }
    guard !recording.samples.isEmpty else {
      captureLogger.error("Every chunk had another rate or layout (\(dropped, privacy: .public) dropped)")
      throw .captureFailed
    }
    captureLogger.notice("Dropped \(dropped, privacy: .public) chunks at another rate or layout")
    return recording
  }

  func stopMic(discardingRecording: Bool) {
    if discardingRecording { recycle(sink.take()) }
    guard let source, !sink.isRecording else { return }
    source.stop()
  }

  private func recycle(_ frames: consuming RawFrames?) {
    guard var frames = consume frames else { return }
    frames.scrub()
    if frames.sampleRate == source?.sampleRate { spare = frames }
  }

  private func teardown() {
    guard let source else { return }
    source.teardown()
    self.source = nil
    device = nil
    spare = nil
  }
}
