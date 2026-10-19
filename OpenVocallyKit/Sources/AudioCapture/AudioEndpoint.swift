/// A connected audio device without its name or UID, for reports that must not carry either. A
/// device name often holds a person's name, such as "Anna's AirPods Pro", and a Bluetooth UID
/// holds the device's hardware address.
public struct AudioEndpoint: Sendable {
  public enum Direction: Sendable { case input, output }

  public let direction: Direction
  public let transport: Microphone.Transport
  public let isSystemDefault: Bool
  /// The input the user picked in Settings.
  public let isChosen: Bool

  /// Every live device once for each direction it has streams in, in CoreAudio's order.
  public static func current(chosenUID: String?) -> [AudioEndpoint] {
    CoreAudioDevices.endpoints(chosenUID: chosenUID)
  }
}
