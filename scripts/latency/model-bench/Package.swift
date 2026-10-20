// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .treatAllWarnings(as: .error), .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
  name: "model-bench",
  platforms: [.macOS(.v26)],
  products: [.executable(name: "model-bench", targets: ["model-bench"])],
  dependencies: [
    .package(path: "../../../OpenVocallyKit"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
  ],
  targets: [
    .executableTarget(
      name: "model-bench",
      dependencies: [
        .product(name: "Models", package: "OpenVocallyKit"),
        .product(name: "Transcription", package: "OpenVocallyKit"),
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      swiftSettings: strict
    ),
    .testTarget(name: "model-benchTests", dependencies: ["model-bench"], swiftSettings: strict),
  ]
)
