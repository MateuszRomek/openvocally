import AVFoundation
import AppKit
import AudioCapture
import Observation
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "app")

enum MicrophoneAccess {
  case granted
  case notDetermined
  case denied

  init(_ status: AVAuthorizationStatus) {
    switch status {
    case .authorized: self = .granted
    case .notDetermined: self = .notDetermined
    default: self = .denied
    }
  }

  static var current: Self { Self(AVCaptureDevice.authorizationStatus(for: .audio)) }
}

/// The microphone: its permission, the connected devices, the user's choice and the capture
/// prepare. The only writer of the capture's device selection.
@MainActor @Observable final class AudioInput {
  private(set) var access = MicrophoneAccess.current {
    didSet {
      guard access != oldValue else { return }
      logger.notice("Microphone access: \(String(describing: self.access), privacy: .public)")
    }
  }
  private(set) var devices = MicrophoneList.empty
  /// The input device the user picked, or nil for the system default.
  private(set) var chosenUID = UserDefaults.standard.string(forKey: uidKey)
  /// The picked device's name, kept so Settings can name it while it is unplugged.
  private(set) var chosenName = UserDefaults.standard.string(forKey: nameKey)

  var active: Microphone? {
    devices.devices.first { $0.uid == chosenUID } ?? devices.systemDefault
  }

  /// Shared with the pipeline and the shutdown. It does its own work off the main actor.
  @ObservationIgnored let capture = AudioCapture()

  private static let uidKey = "microphone.deviceUID"
  private static let nameKey = "microphone.deviceName"

  /// Launch: the prepare when `preparing`, then the device list, then the permission re-read
  /// on activation.
  func start(preparing: Bool) {
    let capture = capture
    if preparing {
      Task { await prepare() }
    }
    Task {
      for await list in capture.microphones { devices = list }
    }
    Task { await refreshOnActivation() }
  }

  /// The Allow button when macOS has not asked yet.
  func requestAccess() async {
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    await prepare()
  }

  /// Asks now if macOS never asked, so the alert can't land on the first shortcut press and
  /// clip the first words.
  func askIfNeverAsked() {
    if access == .notDetermined { Task { await prepare() } }
  }

  func choose(_ microphone: Microphone?) {
    chosenUID = microphone?.uid
    chosenName = microphone?.name
    UserDefaults.standard.set(chosenUID, forKey: Self.uidKey)
    UserDefaults.standard.set(chosenName, forKey: Self.nameKey)
    let capture = capture
    let uid = chosenUID
    Task { await capture.selectDevice(uid: uid) }
  }

  private func prepare() async {
    do throws(CaptureError) {
      try await capture.prepare(deviceUID: chosenUID)
    } catch .microphonePermissionDenied {
    } catch {
      logger.error("Capture prepare failed: \(String(describing: error), privacy: .public)")
    }
    access = .current
  }

  /// The permission changes in System Settings, so it is read again whenever the app comes
  /// back to the front.
  private func refreshOnActivation() async {
    for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
    {
      let now = MicrophoneAccess.current
      guard now != access else { continue }
      access = now
      if now == .granted { await prepare() }
    }
  }
}
