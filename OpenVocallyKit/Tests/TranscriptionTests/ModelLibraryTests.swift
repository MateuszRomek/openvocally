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
      provisioner: Provisioner(folder: folder, fetcher: fetcher, system: NoSystemModels()), runtime: runtime,
      preferences: ModelPreferences(defaults: defaults))
  }

  @Test func `with nothing installed the preferred model stays active and nothing loads`() async {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library()
    await library.start()
    #expect(library.active == .preferred)
    #expect(library.installedModels.isEmpty)
    await eventually { library.runtime == .notInstalled }
    #expect(library.runtime == .notInstalled)
  }

  @Test func `a downloaded model becomes active when the active one is missing`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library()
    await library.start()
    library.install(.parakeetV3)
    #expect(library.state(of: .parakeetV3).readiness == .installing(.downloading(received: 0, total: 12)))

    await eventually { !library.isInstalling && library.installedModels.contains(.parakeetV3) }
    #expect(library.installedModels == [.parakeetV3])
    #expect(library.active == .parakeetV3)
    await eventually { library.runtime == .ready }
    #expect(library.runtime == .ready)
  }

  @Test func `a failed download is kept for the retry message and a cancel is not`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library(fetcher: FakeFetcher(failure: .offline))
    await library.start()
    library.install(.parakeetV3)
    await eventually { !library.isInstalling }
    #expect(library.state(of: .parakeetV3).failure == .download(.offline))

    let waiting = FakeFetcher(waits: true)
    let cancelling = self.library(fetcher: waiting)
    await cancelling.start()
    cancelling.install(.parakeetV3)
    while waiting.fetched.isEmpty { await Task.yield() }
    cancelling.cancelInstall()
    waiting.release()
    await eventually { !cancelling.isInstalling }
    #expect(ModelID.allCases.allSatisfy { cancelling.state(of: $0).failure == nil })
    #expect(cancelling.installedModels.isEmpty)
  }

  @Test func `only an installed model can be selected`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.whisperTurbo, in: folder)
    let library = library()
    await library.start()
    #expect(library.state(of: .whisperTurbo).readiness == .installed)
    #expect(library.state(of: .parakeetV3).readiness == .notInstalled)
    library.select(.parakeetV3)
    #expect(library.active == .whisperTurbo)
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
    #expect(library.state(of: .parakeetV3).recovery == .downloadAgain)
    await library.recover(.parakeetV3)
    await eventually { library.runtime == .ready }
    #expect(library.runtime == .ready)
    #expect(library.installedModels == [.parakeetV3])
  }

  @Test func `deleting the only model is refused`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    let library = library()
    await library.start()
    await #expect(throws: RemoveError.noReplacement) { try await library.remove(.parakeetV3) }
    #expect(library.installedModels == [.parakeetV3])
    #expect(folder.isInstalled(.parakeetV3))
  }

  @Test func `deleting a model that is not active removes it`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    try Fixture.install(.whisperTurbo, in: folder)
    let library = library()
    await library.start()
    try await library.remove(.whisperTurbo)
    #expect(library.installedModels == [.parakeetV3])
    #expect(!FileManager.default.fileExists(atPath: folder.location(of: .whisperTurbo).path))
  }

  @Test func `the saved model is read back and an unknown one falls back`() {
    defaults.set(ModelID.whisperTurbo.rawValue, forKey: ModelPreferences.activeKey)
    #expect(library().active == .whisperTurbo)
    defaults.set("qwen3-asr-0.6b-mlx-bf16", forKey: ModelPreferences.activeKey)
    #expect(library().active == .preferred)
  }

  @Test func `a model downloaded again keeps its files until the new ones land`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    let fetcher = FakeFetcher(waits: true)
    let library = library(fetcher: fetcher)
    await library.start()
    await library.recover(.parakeetV3)
    await eventually { !fetcher.fetched.isEmpty }

    let replacing = library.state(of: .parakeetV3)
    #expect(replacing.isOnDisk)
    #expect(replacing.readiness == .installing(.downloading(received: 0, total: 12)))
    #expect(!replacing.canRemove)

    fetcher.release()
    await eventually { !library.isInstalling }
    #expect(library.state(of: .parakeetV3).readiness == .installed)
  }

  @Test func `an install asked for before launch has checked still downloads`() async {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let library = library()
    library.install(.parakeetV3)
    await library.start()

    await eventually { library.state(of: .parakeetV3).readiness == .installed }
    #expect(library.state(of: .parakeetV3).readiness == .installed)
  }
}
