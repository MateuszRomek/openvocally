import AudioCapture
import Diagnostics
import Foundation
import Hotkeys
import Models
import Overlay
import SoundCues

extension AppModel {
  /// What the diagnostics file reports about this app. Device names and UIDs never leave
  /// AudioCapture: `AudioEndpoint` has no field for either.
  func diagnosticsSnapshot() -> DiagnosticsSnapshot {
    let bundle = Bundle.main
    #if FEATURE_NOTCH
      let overlayDescription = "notch"
    #else
      let overlay = OverlayPreference.stored()
      let overlayDescription =
        "\(overlay.style.rawValue), \(UserDefaults.standard.string(forKey: IslandEdge.defaultsKey) ?? "default edge")"
    #endif
    let cues = SoundCueSettings.load(from: .standard)
    let settings = [
      DiagnosticsSetting("Speech model", models.active.rawValue),
      DiagnosticsSetting(
        "Installed models", models.installedModels.map(\.rawValue).sorted().joined(separator: ", ")),
      DiagnosticsSetting("Model runtime", String(describing: models.runtime)),
      DiagnosticsSetting(
        "Download failures",
        ModelID.allCases.compactMap { id in models.state(of: id).failure.map { "\(id.rawValue): \($0)" } }
          .sorted().joined(separator: ", ")),
      DiagnosticsSetting("Microphone access", String(describing: input.access)),
      DiagnosticsSetting("Accessibility", shortcuts.accessibilityGranted ? "granted" : "not granted"),
      DiagnosticsSetting("Shortcuts", String(describing: shortcuts.availability)),
      DiagnosticsSetting(
        "Bindings",
        HotkeyAction.allCases.map { "\($0) \(shortcuts.bindings.trigger(for: $0)?.label ?? "unbound")" }
          .joined(separator: ", ")),
      DiagnosticsSetting(
        "Microphone choice", input.chosenUID == nil ? "system default" : "chosen in Settings"),
      DiagnosticsSetting("Overlay", overlayDescription),
      DiagnosticsSetting("Sound cues", cues.enabled ? "on, volume \(cues.volume)" : "off"),
      DiagnosticsSetting(
        "Onboarding finished", String(UserDefaults.standard.bool(forKey: Onboarding.completedKey))),
    ]
    let devices = AudioEndpoint.current(chosenUID: input.chosenUID).map { endpoint in
      DiagnosticsDevice(
        direction: endpoint.direction == .input ? .input : .output,
        transport: Self.diagnosticsTransport(endpoint.transport),
        isChosen: endpoint.isChosen,
        isSystemDefault: endpoint.isSystemDefault)
    }
    return DiagnosticsSnapshot(
      bundleID: bundle.bundleIdentifier ?? "unknown",
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      settings: settings, devices: devices)
  }

  private static func diagnosticsTransport(_ transport: Microphone.Transport) -> DiagnosticsDevice.Transport {
    switch transport {
    case .builtIn: .builtIn
    case .usb: .usb
    case .bluetooth: .bluetooth
    case .other: .other
    }
  }
}
