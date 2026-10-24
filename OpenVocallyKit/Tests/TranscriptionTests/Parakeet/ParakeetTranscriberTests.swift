import Foundation
import ModelsTestSupport
import Testing

@testable import Models
@testable import Transcription

struct ParakeetTranscriberTests {
  static let models = [
    "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
  ]
  static let vocabulary = "parakeet_vocab.json"
  static let installedFiles = models + [vocabulary]

  static let variants: [ParakeetVariant] = [.v3, .ultra]

  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  func repository(of variant: ParakeetVariant) -> URL {
    directory.appending(path: ParakeetTranscriber.repositoryFolder(of: variant))
  }

  func install(_ files: some Sequence<String>, of variant: ParakeetVariant = .v3) throws {
    let repository = repository(of: variant)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    for file in files {
      let url = repository.appending(path: file)
      if file == Self.vocabulary {
        let tokens = Dictionary(uniqueKeysWithValues: (0..<8193).map { (String($0), "t\($0)") })
        try JSONEncoder().encode(tokens).write(to: url)
      } else {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: url.appending(path: "coremldata.bin"))
      }
    }
  }

  @Test(arguments: [
    (ParakeetVariant.v3, "parakeet-tdt-0.6b-v3"), (.ultra, "parakeet-ultra"),
  ])
  func repositoryFolderMatchesFluidAudioLayout(variant: ParakeetVariant, folder: String) {
    #expect(ParakeetTranscriber.repositoryFolder(of: variant) == folder)
  }

  @Test func installedFilesMatchFluidAudio() {
    #expect(ParakeetTranscriber.installedFiles == Set(Self.installedFiles))
  }

  @Test(arguments: variants, installedFiles)
  func missingFileMeansNotInstalled(model: ParakeetVariant, missing: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try install(Self.installedFiles.filter { $0 != missing }, of: model)

    await #expect(throws: TranscriptionError.modelNotInstalled) {
      try await ParakeetTranscriber.load(model, modelDirectory: directory)
    }
  }

  @Test(arguments: variants)
  func missingFolderMeansNotInstalled(model: ParakeetVariant) async {
    await #expect(throws: TranscriptionError.modelNotInstalled) {
      try await ParakeetTranscriber.load(model, modelDirectory: directory)
    }
  }

  @Test(arguments: variants)
  func corruptModelFailsWithoutDeletingIt(model: ParakeetVariant) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try install(Self.installedFiles, of: model)

    await #expect(throws: TranscriptionError.engineFailed) {
      try await ParakeetTranscriber.load(model, modelDirectory: directory)
    }
    let repository = repository(of: model)
    for file in Self.installedFiles {
      #expect(FileManager.default.fileExists(atPath: repository.appending(path: file).path))
    }
    for component in Self.models {
      let junk = repository.appending(path: component).appending(path: "coremldata.bin")
      #expect(FileManager.default.fileExists(atPath: junk.path))
    }
  }
}

struct ParakeetManifestTests {
  @Test(arguments: [HostedModel.parakeetV3, .parakeetUltra])
  func `Parakeet installs every file FluidAudio loads`(model: HostedModel) throws {
    guard case .parakeet(let variant) = model.engine else { throw ParakeetManifestError.notParakeet }
    let folder = ParakeetTranscriber.repositoryFolder(of: variant)
    let manifest = model.pinned
    let paths = Set(manifest.files.map { manifest.localPath(for: $0) })
    for file in ParakeetTranscriber.installedFiles {
      #expect(paths.contains { $0.hasPrefix("\(folder)/\(file)") }, "\(file)")
    }
  }
}

private enum ParakeetManifestError: Error { case notParakeet }
