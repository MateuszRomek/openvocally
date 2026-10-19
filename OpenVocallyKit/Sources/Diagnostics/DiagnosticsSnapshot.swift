import Foundation

/// What the app knows about itself when the user asks for a diagnostics file.
public struct DiagnosticsSnapshot: Sendable {
  let bundleID: String
  let version: String
  let build: String
  let settings: [DiagnosticsSetting]
  let devices: [DiagnosticsDevice]

  public init(
    bundleID: String, version: String, build: String, settings: [DiagnosticsSetting],
    devices: [DiagnosticsDevice]
  ) {
    self.bundleID = bundleID
    self.version = version
    self.build = build
    self.settings = settings
    self.devices = devices
  }
}

public struct DiagnosticsSetting: Sendable {
  let name: String
  let value: String

  public init(_ name: String, _ value: String) {
    self.name = name
    self.value = value
  }
}

/// No name and no UID field, so a device name cannot reach the file.
public struct DiagnosticsDevice: Sendable {
  public enum Direction: Sendable { case input, output }
  public enum Transport: Sendable { case builtIn, usb, bluetooth, other }

  let direction: Direction
  let transport: Transport
  let isChosen: Bool
  let isSystemDefault: Bool

  public init(direction: Direction, transport: Transport, isChosen: Bool, isSystemDefault: Bool) {
    self.direction = direction
    self.transport = transport
    self.isChosen = isChosen
    self.isSystemDefault = isSystemDefault
  }
}
