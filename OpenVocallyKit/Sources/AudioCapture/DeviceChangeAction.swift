/// What a device list change means for the mic. Pure, so it is testable without hardware.
enum DeviceChangeAction: Equatable, Sendable {
  case none
  /// The recording's device is gone: end the recording now.
  case interrupt
  /// Not recording: drop the warm mic and prepare the newly selected device.
  case reselect

  /// While recording only a vanished device matters; a changed selection waits for the
  /// recording to end, when the controller reconciles.
  static func decide(
    recording: Bool, active: InputDevice?, selected: InputDevice?, devices: [InputDevice]
  ) -> DeviceChangeAction {
    let activePresent = active.map { isPresent($0, in: devices) }
    if recording { return activePresent == false ? .interrupt : .none }
    if activePresent == true, selected?.uid == active?.uid { return .none }
    return .reselect
  }

  static func isPresent(_ device: InputDevice, in devices: [InputDevice]) -> Bool {
    devices.contains { $0.uid == device.uid && $0.isUsable }
  }
}
