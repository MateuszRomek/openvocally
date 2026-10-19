import CoreAudio

public struct Microphone: Equatable, Hashable, Sendable, Identifiable {
  public let uid: String
  public let name: String
  public let transport: Transport

  public var id: String { uid }

  public init(uid: String, name: String, transport: Transport = .other) {
    self.uid = uid
    self.name = name
    self.transport = transport
  }

  public enum Transport: Sendable, Hashable {
    case builtIn
    case usb
    /// Wakes slowly and records in a narrower headset profile.
    case bluetooth
    /// Continuity, virtual, aggregate and anything else.
    case other
  }
}

/// The usable input devices and which one the system uses by default.
public struct MicrophoneList: Equatable, Sendable {
  public let devices: [Microphone]
  let systemDefaultUID: String?

  public init(devices: [Microphone], systemDefaultUID: String?) {
    self.devices = devices
    self.systemDefaultUID = systemDefaultUID
  }

  public static let empty = MicrophoneList(devices: [], systemDefaultUID: nil)

  public var systemDefault: Microphone? {
    devices.first { $0.uid == systemDefaultUID }
  }
}
