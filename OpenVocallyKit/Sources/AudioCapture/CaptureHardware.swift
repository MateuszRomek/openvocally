import AVFoundation
import DictationCore

/// What the controller asks of a recorder. Calls run one at a time in the order they arrive,
/// as `Recorder`'s serial queue runs them, so a slow call holds back the ones behind it.
protocol CaptureRecorder: Actor {
  nonisolated var sink: FrameSink { get }
  var isRunning: Bool { get }
  func prepare(device: InputDevice?) async throws(CaptureError)
  func start(pressedAt press: HostTime, device: InputDevice?) async throws(CaptureError) -> MicStart
  func restart() async throws(CaptureError)
  func finishRecording(releasedAt release: HostTime) async throws(CaptureError) -> Recording
  func stopMic(discardingRecording: Bool) async
  func shutdown() async
}

extension Recorder: CaptureRecorder {}

/// The system the controller reaches: the input devices, the microphone permission and the
/// recorder. Tests replace it to run the controller without a microphone.
struct CaptureHardware: Sendable {
  var inputDevices: @Sendable () -> [InputDevice]
  var defaultInputUID: @Sendable () -> String?
  var permission: @Sendable () -> AVAuthorizationStatus
  var requestPermission: @Sendable () async -> Bool
  /// The closure reports the recorder's `ObjectIdentifier` when its capture session stops.
  var makeRecorder:
    @Sendable (_ onSourceStopped: @escaping @Sendable (ObjectIdentifier) -> Void) -> any CaptureRecorder

  static let live = CaptureHardware(
    inputDevices: { CoreAudioDevices.inputDevices() },
    defaultInputUID: { CoreAudioDevices.defaultInputUID() },
    permission: { AVCaptureDevice.authorizationStatus(for: .audio) },
    requestPermission: { await AVCaptureDevice.requestAccess(for: .audio) },
    makeRecorder: { Recorder(onSourceStopped: $0) })
}
