import AVFoundation
import CoreMedia
import DictationCore

/// Records the selected input through AVCaptureSession, which opens that device by its UID and
/// never the system default input. The session is configured here, which does not move
/// AirPods into the headset profile; `start` runs it. Confined to the Recorder executor;
/// samples arrive on the session's own delivery queue.
final class SessionSource {
  private let session: AVCaptureSession
  private let captureDevice: AVCaptureDevice
  private let input: AVCaptureDeviceInput
  private let output: AVCaptureAudioDataOutput
  private let receiver: SampleReceiver
  private let queue = DispatchQueue(label: "com.openvocally.capture.session", qos: .userInteractive)
  private var observers: [any NSObjectProtocol] = []
  let sampleRate: Double

  /// The CoreAudio UID equals `AVCaptureDevice.uniqueID`. Throws `.noInputDevice` when the
  /// lookup fails and `.captureFailed` when the session refuses the input or output.
  init(device: InputDevice, sink: FrameSink, onStopped: @escaping @Sendable () -> Void) throws(CaptureError) {
    guard let captureDevice = AVCaptureDevice(uniqueID: device.uid) else {
      captureLogger.error("No capture device for \(device.uid, privacy: .private)")
      throw .noInputDevice
    }
    guard let rate = CoreAudioDevices.nominalInputRate(of: device.id) else {
      captureLogger.error("No nominal input rate for \(device.uid, privacy: .private)")
      throw .captureFailed
    }
    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: captureDevice)
    } catch {
      captureLogger.error("Capture input failed: \(error.localizedDescription, privacy: .public)")
      throw .captureFailed
    }
    let session = AVCaptureSession()
    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    session.beginConfiguration()
    let added = session.canAddInput(input) && session.canAddOutput(output)
    if added {
      session.addInput(input)
      session.addOutput(output)
    }
    session.commitConfiguration()
    guard added else {
      captureLogger.error("Capture session refused the input or output")
      throw .captureFailed
    }
    let receiver = SampleReceiver(sink: sink)
    output.setSampleBufferDelegate(receiver, queue: queue)
    self.session = session
    self.output = output
    self.receiver = receiver
    self.captureDevice = captureDevice
    self.input = input
    sampleRate = rate
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
        _ in
        onStopped()
      },
      center.addObserver(
        forName: AVCaptureDevice.wasDisconnectedNotification, object: captureDevice, queue: nil
      ) {
        _ in onStopped()
      },
      center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
        _ in
        onStopped()
      },
      center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) {
        _ in
        onStopped()
      },
    ]
  }

  var isRunning: Bool {
    session.isRunning && captureDevice.isConnected
  }

  func start() throws(CaptureError) {
    session.startRunning()
    guard isRunning else {
      captureLogger.error("Capture session did not start")
      throw .captureFailed
    }
  }

  func restart() throws(CaptureError) {
    try start()
  }

  func stop() {
    if session.isRunning { session.stopRunning() }
  }

  deinit {
    teardown()
  }

  func teardown() {
    guard !observers.isEmpty else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if session.isRunning { session.stopRunning() }
    output.setSampleBufferDelegate(nil, queue: nil)
    session.beginConfiguration()
    session.removeOutput(output)
    session.removeInput(input)
    session.commitConfiguration()
  }
}

/// Runs on the session's delivery queue and holds only immutable Sendable state.
private final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
  private let sink: FrameSink
  init(sink: FrameSink) {
    self.sink = sink
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      stream.mFormatID == kAudioFormatLinearPCM, stream.mBitsPerChannel == 32,
      stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
      let block = CMSampleBufferGetDataBuffer(sampleBuffer)
    else {
      sink.noteDropped()
      return
    }
    var length = 0
    var total = 0
    var data: UnsafeMutablePointer<CChar>?
    guard
      CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total, dataPointerOut: &data)
        == kCMBlockBufferNoErr,
      length == total, let data
    else {
      sink.noteDropped()
      return
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let start = pts.isNumeric ? SessionClock.hostTime(of: pts) : nil
    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: stream.mChannelsPerFrame, mDataByteSize: UInt32(total),
        mData: UnsafeMutableRawPointer(data)))
    withUnsafePointer(to: &list) { list in
      sink.receive(
        list: list, frames: CMSampleBufferGetNumSamples(sampleBuffer), at: start, rate: stream.mSampleRate)
    }
  }
}

/// Sample timestamps are on the session's synchronization clock, which exists only once the
/// session runs and keeps host time on macOS, so every chunk is read as host time.
enum SessionClock {
  static func hostTime(of time: CMTime) -> HostTime {
    HostTime(ticks: CMClockConvertHostTimeToSystemUnits(time))
  }
}
