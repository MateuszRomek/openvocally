/// A command with the time it happened. For a key, `at` is the key event's own timestamp, or the
/// current time for a stop synthesized by a tap reset or a rebind.
public struct StampedCommand: Sendable, Equatable {
  public let command: DictationCommand
  public let at: HostTime

  public init(command: DictationCommand, at: HostTime) {
    self.command = command
    self.at = at
  }
}
