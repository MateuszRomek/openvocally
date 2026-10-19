/// The app that received the paste.
public struct TargetApp: Sendable, Equatable {
  public let name: String?
  public let bundleIdentifier: String?

  public init(name: String?, bundleIdentifier: String?) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
  }
}
