import Foundation
import ModelsTestSupport
import Synchronization
import Testing

@testable import Models
@testable import Transcription

@MainActor struct ModelLibraryTests {
  let folder = Fixture.folder()
  let defaults: UserDefaults
  let log = LoadLog()

  init() throws {
    let suite = "ModelLibraryTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  func library(fetcher: FakeFetcher = FakeFetcher()) -> ModelLibrary {
    let log = log
    let runtime = TranscriptionRuntime(
      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
      load: { (model) throws(TranscriptionError) in try log.load(model) })
    return ModelLibrary(
      folder: folder, downloader: ModelDownloader(folder: folder, fetcher: fetcher), runtime: runtime,
      defaults: defaults)
  }

  @Test func `with nothing installed the preferred model stays active and nothing loads`() async {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library()
    await library.start()
    #expect(library.active == .preferred)
    #expect(library.installed.isEmpty)
    await eventually { library.runtime == .notInstalled }
    #expect(library.runtime == .notInstalled)
  }

  @Test func `a downloaded model becomes active when the active one is missing`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library()
    await library.start()
    library.startDownload(.parakeetV3)
    #expect(library.download?.model == .parakeetV3)

    await eventually { library.download == nil && library.installed.contains(.parakeetV3) }
    #expect(library.installed == [.parakeetV3])
    #expect(library.active == .parakeetV3)
    await eventually { library.runtime == .ready }
    #expect(library.runtime == .ready)
  }

  @Test func `a failed download is kept for the retry message and a cancel is not`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library(fetcher: FakeFetcher(failure: .offline))
    await library.start()
    library.startDownload(.parakeetV3)
    await eventually { library.download == nil }
    #expect(library.failures[.parakeetV3] == .offline)

    let waiting = FakeFetcher(waits: true)
    let cancelling = self.library(fetcher: waiting)
    await cancelling.start()
    cancelling.startDownload(.parakeetV3)
    while waiting.fetched.isEmpty { await Task.yield() }
    cancelling.cancelDownload()
    waiting.release()
    await eventually { cancelling.download == nil }
    #expect(cancelling.failures.isEmpty)
    #expect(cancelling.installed.isEmpty)
  }

  @Test func `only an installed model can be selected`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.whisperTurbo, in: folder)
    let library = library()
    await library.start()
    #expect(library.canSelect(.whisperTurbo))
    #expect(!library.canSelect(.parakeetV3))
  }

  @Test func `downloading a model that won't load again loads it`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    log.fail(true)
    let library = library()
    await library.start()
    await eventually { library.runtime == .failed }
    #expect(library.runtime == .failed)

    log.fail(false)
    library.redownload(.parakeetV3)
    await eventually { library.runtime == .ready }
    #expect(library.runtime == .ready)
    #expect(library.installed == [.parakeetV3])
  }

  @Test func `deleting the only model is refused`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    let library = library()
    await library.start()
    await #expect(throws: ModelLibrary.DeleteError.noReplacement) { try await library.delete(.parakeetV3) }
    #expect(library.installed == [.parakeetV3])
    #expect(folder.isInstalled(.parakeetV3))
  }

  @Test func `deleting a model that is not active removes it`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    try Fixture.install(.whisperTurbo, in: folder)
    let library = library()
    await library.start()
    try await library.delete(.whisperTurbo)
    #expect(library.installed == [.parakeetV3])
    #expect(!FileManager.default.fileExists(atPath: folder.location(of: .whisperTurbo).path))
  }

  @Test func `the saved model is read back and an unknown one falls back`() {
    defaults.set(ModelID.whisperTurbo.rawValue, forKey: ModelLibrary.activeKey)
    #expect(library().active == .whisperTurbo)
    defaults.set("qwen3-asr-0.6b-mlx-bf16", forKey: ModelLibrary.activeKey)
    #expect(library().active == .preferred)
  }
}
