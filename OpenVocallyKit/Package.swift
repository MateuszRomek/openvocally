// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let agentsSettings = strict + [.define("FEATURE_AGENTS", .when(configuration: .debug))]

let package = Package(
  name: "OpenVocallyKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "AudioCapture", targets: ["AudioCapture"]),
    .library(name: "DictationCore", targets: ["DictationCore"]),
    .library(name: "Hotkeys", targets: ["Hotkeys"]),
    .library(name: "Paste", targets: ["Paste"]),
    .library(name: "Overlay", targets: ["Overlay"]),
    .library(name: "Dictation", targets: ["Dictation"]),
    .library(name: "Models", targets: ["Models"]),
    .library(name: "Transcription", targets: ["Transcription"]),
    .library(name: "SoundCues", targets: ["SoundCues"]),
    .library(name: "DesignSystem", targets: ["DesignSystem"]),
    .library(name: "Storage", targets: ["Storage"]),
    .library(name: "Reporting", targets: ["Reporting"]),
    .library(name: "Diagnostics", targets: ["Diagnostics"]),
    .library(name: "Agents", targets: ["Agents"]),
  ],
  dependencies: [
    // NemoTextProcessing normalizes text for FluidAudio's TTS, which the app does not use.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
  ],
  targets: [
    .target(
      name: "AudioCapture", dependencies: ["DictationCore"], swiftSettings: strict),
    .testTarget(
      name: "AudioCaptureTests", dependencies: ["AudioCapture", "DictationCore"], swiftSettings: strict),
    .target(name: "DictationCore", swiftSettings: strict),
    .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"], swiftSettings: strict),
    .target(name: "Hotkeys", dependencies: ["DictationCore"], swiftSettings: strict),
    .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys", "DictationCore"], swiftSettings: strict),
    .target(
      name: "Transcription",
      dependencies: [
        "Models", .product(name: "FluidAudio", package: "FluidAudio"), "whisper",
      ],
      swiftSettings: strict
    ),
    // Built by scripts/whisper/build-xcframework.sh; run `make whisper` first.
    .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    .target(name: "Paste", dependencies: ["DictationCore"], swiftSettings: strict),
    .testTarget(name: "PasteTests", dependencies: ["Paste", "DictationCore"], swiftSettings: strict),
    .target(name: "DesignSystem", swiftSettings: strict),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"], swiftSettings: strict),
    .target(name: "OverlayCore", dependencies: ["DictationCore"], swiftSettings: strict),
    .testTarget(
      name: "OverlayCoreTests", dependencies: ["OverlayCore", "DictationCore"], swiftSettings: strict),
    .target(
      name: "Overlay", dependencies: ["DesignSystem", "DictationCore", "OverlayCore"], swiftSettings: strict),
    .testTarget(
      name: "OverlayTests", dependencies: ["Overlay", "DictationCore", "OverlayCore"], swiftSettings: strict),
    .target(
      name: "Dictation",
      dependencies: ["DictationCore", "AudioCapture", "Transcription", "Paste"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "DictationTests",
      dependencies: ["AudioCapture", "Dictation", "DictationCore", "Hotkeys", "Paste", "Transcription"],
      swiftSettings: strict),
    .target(name: "SoundCues", dependencies: ["DictationCore"], swiftSettings: strict),
    .testTarget(name: "SoundCuesTests", dependencies: ["SoundCues", "DictationCore"], swiftSettings: strict),
    .target(
      name: "Storage",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "DictationCore", "Hotkeys", "Reporting"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "StorageTests",
      dependencies: [
        "Storage", "DictationCore", "Hotkeys", "Reporting", .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.copy("Snapshots")],
      swiftSettings: strict),
    .target(name: "Reporting", swiftSettings: strict),
    .testTarget(name: "ReportingTests", dependencies: ["Reporting"], swiftSettings: strict),
    .target(name: "Diagnostics", swiftSettings: strict),
    .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"], swiftSettings: strict),
    .target(name: "Models", swiftSettings: strict),
    // Fixture models and a fake fetcher, shared by the Models and Transcription tests.
    .target(
      name: "ModelsTestSupport", dependencies: ["Models"], path: "Tests/ModelsTestSupport",
      swiftSettings: strict),
    .testTarget(
      name: "ModelsTests", dependencies: ["Models", "ModelsTestSupport"], swiftSettings: strict),
    .testTarget(
      name: "TranscriptionTests",
      dependencies: ["Models", "ModelsTestSupport", "Transcription"],
      swiftSettings: strict),
    .target(name: "AgentFakes", swiftSettings: strict),
    .executableTarget(name: "FakeAgentCLI", dependencies: ["AgentFakes"], swiftSettings: strict),
    // Depends on the executable so `swift test` builds it next to the test bundle.
    .target(
      name: "AgentFakesTestSupport", dependencies: ["AgentFakes", "FakeAgentCLI"],
      path: "Tests/AgentFakesTestSupport", swiftSettings: strict),
    .target(name: "Agents", swiftSettings: agentsSettings),
    .testTarget(
      name: "AgentsTests", dependencies: ["Agents", "AgentFakes", "AgentFakesTestSupport"],
      swiftSettings: agentsSettings),
    .testTarget(
      name: "AgentFakesTests", dependencies: ["AgentFakes", "AgentFakesTestSupport"], swiftSettings: strict),
  ]
)
