import Foundation
import ModelsTestSupport
import Synchronization
import Testing

@testable import Models

struct ModelCatalogTests {
  @Test(arguments: ModelID.allCases)
  func `every pinned file has a size and a SHA-256`(model: ModelID) {
    let manifest = model.manifest
    #expect(!manifest.files.isEmpty)
    #expect(manifest.revision.count == 40)
    for file in manifest.files {
      #expect(file.size > 0)
      #expect(file.sha256.count == 64)
    }
  }

  @Test func `files download from the pinned revision`() {
    let manifest = ModelID.whisperTurbo.manifest
    #expect(
      manifest.remoteURL(for: manifest.files[0]).absoluteString
        == "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin"
    )
  }

  @Test func `models install under the bundle ID local-models folder`() {
    let folder = ModelFolder.default(bundleIdentifier: "com.openvocally.app.debug")
    #expect(
      folder.location(of: .parakeetV3).path(percentEncoded: false).hasSuffix(
        "Application Support/com.openvocally.app.debug/local-models/parakeet/parakeet-tdt-0.6b-v3-coreml/"))
    #expect(
      folder.location(of: .whisperTurbo).path().hasSuffix("local-models/whisper/ggml-large-v3-turbo.bin")
    )
  }
}

struct ModelFolderTests {
  let folder = Fixture.folder()

  @Test func `a model is installed only when every file has its pinned size`() throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    #expect(!folder.isInstalled(.parakeetV3))
    try Fixture.install(.parakeetV3, in: folder)
    try Fixture.install(.whisperTurbo, in: folder)
    #expect(folder.installedModels() == [.parakeetV3, .whisperTurbo])

    try Data("alph".utf8).write(to: folder.location(of: .parakeetV3).appending(path: "folder/a.bin"))
    #expect(!folder.isInstalled(.parakeetV3))
    try FileManager.default.removeItem(at: folder.location(of: .whisperTurbo))
    #expect(folder.installedModels().isEmpty)
  }

  @Test func `the sweep removes downloads an hour old and keeps newer ones`() throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let now = Date(timeIntervalSince1970: 1_000_000)
    let old = folder.stagingFolder(for: .parakeetV3, at: now.addingTimeInterval(-3600))
    let fresh = folder.stagingFolder(for: .whisperTurbo, at: now.addingTimeInterval(-60))
    for (url, age) in [(old, 3600.0), (fresh, 3599.0)] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    try Fixture.install(.parakeetV3, in: folder)

    folder.sweepStaleDownloads(now: now)

    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    #expect(folder.isInstalled(.parakeetV3))
  }
}

struct ModelDownloaderTests {
  let folder = Fixture.folder()

  func stagingEntries() -> [String] {
    Engine.allCases.flatMap { engine in
      let url = folder.root.appending(path: engine.rawValue)
      return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter {
        $0.hasSuffix(".download")
      }
    }
  }

  @Test(arguments: [ModelID.parakeetV3, .parakeetUltra, .whisperTurbo])
  func `a verified download is installed and the staging folder is gone`(model: ModelID) async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let reports = Reports()
    try await ModelDownloader(folder: folder, fetcher: FakeFetcher()).install(model) { reports.append($0) }

    #expect(folder.isInstalled(model))
    #expect(stagingEntries().isEmpty)
    let total = Fixture.manifest(model).totalBytes
    #expect(reports.all.first == .downloading(received: 0, total: total))
    #expect(reports.all.contains(.downloading(received: total, total: total)))
    #expect(reports.all.last == .verifying)
  }

  @Test func `a file with the wrong bytes fails verification and installs nothing`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let fetcher = FakeFetcher(overrides: ["folder/b.json": Data("{\"b\":2}".utf8)])

    await #expect(throws: DownloadError.corrupted) {
      try await ModelDownloader(folder: folder, fetcher: fetcher).install(.parakeetV3) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: folder.location(of: .parakeetV3).path))
    #expect(stagingEntries().isEmpty)
  }

  @Test func `a network failure leaves no partial model`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    await #expect(throws: DownloadError.offline) {
      try await ModelDownloader(folder: folder, fetcher: FakeFetcher(failure: .offline)).install(.parakeetV3)
      { _ in }
    }
    #expect(!folder.isInstalled(.parakeetV3))
    #expect(stagingEntries().isEmpty)
  }

  @Test func `only one model downloads at a time`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let fetcher = FakeFetcher(waits: true)
    let downloader = ModelDownloader(folder: folder, fetcher: fetcher)
    let first = Task { try await downloader.install(.parakeetV3) { _ in } }
    while fetcher.fetched.isEmpty { await Task.yield() }

    await #expect(throws: DownloadError.busy) { try await downloader.install(.whisperTurbo) { _ in } }
    fetcher.release()
    try await first.value
    #expect(folder.isInstalled(.parakeetV3))
    #expect(!folder.isInstalled(.whisperTurbo))
  }

  @Test func `cancelling stops the download and removes what it fetched`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let fetcher = FakeFetcher(waits: true)
    let downloader = ModelDownloader(folder: folder, fetcher: fetcher)
    let task = Task { try await downloader.install(.parakeetV3) { _ in } }
    while fetcher.fetched.isEmpty { await Task.yield() }

    task.cancel()
    fetcher.release()
    await #expect(throws: DownloadError.cancelled) { try await task.value }
    #expect(fetcher.fetched == ["folder/a.bin"])
    #expect(!FileManager.default.fileExists(atPath: folder.location(of: .parakeetV3).path))
    #expect(stagingEntries().isEmpty)
  }

  @Test func `replacing keeps the old files until the new ones pass verification`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    let broken = FakeFetcher(overrides: ["folder/a.bin": Data("alphX".utf8)])
    await #expect(throws: DownloadError.corrupted) {
      try await ModelDownloader(folder: folder, fetcher: broken).install(.parakeetV3, replacing: true) { _ in
      }
    }
    #expect(folder.isInstalled(.parakeetV3))

    let fetcher = FakeFetcher()
    try await ModelDownloader(folder: folder, fetcher: fetcher).install(.parakeetV3, replacing: true) { _ in }
    #expect(fetcher.fetched.sorted() == ["folder/a.bin", "folder/b.json"])
    #expect(folder.isInstalled(.parakeetV3))
  }

  @Test func `an installed model downloads nothing`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.whisperTurbo, in: folder)
    let fetcher = FakeFetcher()
    try await ModelDownloader(folder: folder, fetcher: fetcher).install(.whisperTurbo) { _ in }
    #expect(fetcher.fetched.isEmpty)
  }
}

final class Reports: Sendable {
  private let state = Mutex<[DownloadProgress]>([])
  var all: [DownloadProgress] { state.withLock { $0 } }
  func append(_ progress: DownloadProgress) { state.withLock { $0.append(progress) } }
}
