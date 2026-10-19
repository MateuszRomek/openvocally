// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "capture-probe",
  platforms: [.macOS(.v26)],
  dependencies: [.package(path: "../../../OpenVocallyKit")],
  targets: [
    .executableTarget(
      name: "capture-probe",
      dependencies: [
        .product(name: "AudioCapture", package: "OpenVocallyKit"),
        .product(name: "DictationCore", package: "OpenVocallyKit"),
      ],
      swiftSettings: [.treatAllWarnings(as: .error)]
    )
  ]
)
