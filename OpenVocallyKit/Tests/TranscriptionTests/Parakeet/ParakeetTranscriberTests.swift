import Foundation
import Testing

@testable import Models
@testable import Transcription

struct ParakeetTranscriberTests {
  static let models = [
    "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
  ]
  static let vocabulary = "parakeet_vocab.json"
  static let installedFiles = models + [vocabulary]

  static let parakeetModels = ModelID.allCases.filter { $0.engine == .parakeet }

  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  func repository(of model: ModelID) throws -> URL {
    directory.appending(path: try #require(ParakeetTranscriber.repositoryFolder(of: model)))
  }

  func install(_ files: some Sequence<String>, of model: ModelID = .parakeetV3) throws {
    let repository = try repository(of: model)
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
    (ModelID.parakeetV3, "parakeet-tdt-0.6b-v3"), (.parakeetUltra, "parakeet-ultra"),
  ])
  func repositoryFolderMatchesFluidAudioLayout(model: ModelID, folder: String) {
    #expect(ParakeetTranscriber.repositoryFolder(of: model) == folder)
  }

  @Test func whisperHasNoParakeetFolder() {
    #expect(ParakeetTranscriber.repositoryFolder(of: .whisperTurbo) == nil)
  }

  @Test func installedFilesMatchFluidAudio() {
    #expect(ParakeetTranscriber.installedFiles == Set(Self.installedFiles))
  }

  @Test(arguments: parakeetModels, installedFiles)
  func missingFileMeansNotInstalled(model: ModelID, missing: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try install(Self.installedFiles.filter { $0 != missing }, of: model)

    await #expect(throws: TranscriptionError.modelNotInstalled) {
      try await ParakeetTranscriber.load(model, modelDirectory: directory)
    }
  }

  @Test(arguments: parakeetModels)
  func missingFolderMeansNotInstalled(model: ModelID) async {
    await #expect(throws: TranscriptionError.modelNotInstalled) {
      try await ParakeetTranscriber.load(model, modelDirectory: directory)
    }
  }

  @Test(arguments: parakeetModels)
  func corruptModelFailsWithoutDeletingIt(model: ModelID) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try install(Self.installedFiles, of: model)

    await #expect(throws: TranscriptionError.engineFailed) {
      try await ParakeetTranscriber.load(model, modelDirectory: directory)
    }
    let repository = try repository(of: model)
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
  @Test(arguments: [DownloadableModel.parakeetV3, .parakeetUltra])
  func `Parakeet installs every file FluidAudio loads`(model: DownloadableModel) throws {
    let folder = try #require(ParakeetTranscriber.repositoryFolder(of: model.id))
    let paths = Set(model.manifest.files.map { model.manifest.localPath(for: $0) })
    for file in ParakeetTranscriber.installedFiles {
      #expect(paths.contains { $0.hasPrefix("\(folder)/\(file)") }, "\(file)")
    }
  }
}
