import CoreAudio

struct InputDevice: Equatable, Sendable {
  let uid: String
  let id: AudioDeviceID
  let isAlive: Bool
  let hasInput: Bool
  let isAggregateOrVirtual: Bool
  var transport = Microphone.Transport.other

  var isUsable: Bool { isAlive && hasInput }
}

enum InputDevicePolicy {
  static func select(saved: String?, systemDefault: String?, devices: [InputDevice]) -> InputDevice? {
    for uid in [saved, systemDefault].compactMap(\.self) {
      if let device = devices.first(where: { $0.uid == uid && $0.isUsable }) { return device }
    }
    return devices.first { $0.isUsable && !$0.isAggregateOrVirtual }
  }
}
