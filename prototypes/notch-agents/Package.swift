// swift-tools-version: 6.2
import PackageDescription

// Throwaway prototype for "The notch on every display". Not part of the app; delete it once the
// decision is recorded.

let package = Package(
  name: "NotchAgentsLab",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(
      name: "NotchAgentsLab",
      // The app's menu bar logo, copied from App/Resources so the lab stays standalone.
      resources: [.copy("Resources/logo.svg")],
      swiftSettings: [
        .treatAllWarnings(as: .error),
        .defaultIsolation(MainActor.self),
      ]
    )
  ]
)
