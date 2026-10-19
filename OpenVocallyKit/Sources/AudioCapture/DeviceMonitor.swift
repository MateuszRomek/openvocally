import CoreAudio
import Dispatch

/// Listens for the device list and the default input changing. The app holds one
/// `AudioCapture` for its lifetime, so the listeners are never removed.
enum DeviceMonitor {
  static func start(_ continuation: AsyncStream<Void>.Continuation) {
    let queue = DispatchQueue(label: "com.openvocally.capture.devices")
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, queue
      ) {
        _, _ in
        continuation.yield()
      }
      if status != noErr {
        captureLogger.error("Device listener failed: \(status, privacy: .public)")
      }
    }
  }
}
