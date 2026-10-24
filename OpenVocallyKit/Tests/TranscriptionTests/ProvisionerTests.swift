import Foundation
import ModelsTestSupport
import Testing

@testable import Models
@testable import Transcription

struct ProvisionerTests {
  let folder = Fixture.folder()
  let defaults: UserDefaults

  init() throws {
    let suite = "ProvisionerTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  @Test func `preparing a missing system model installs its language and keeps the active model`() async {
    let store = FakeSystemModels(available: [.dictation, .speech])
    defaults.set(ModelID.whisperTurbo.rawValue, forKey: ModelPreferences.activeKey)
    defaults.set("pl_PL", forKey: ModelPreferences.localeKey(.speech))
    let fetcher = FakeFetcher()
    let provisioner = Provisioner(folder: folder, fetcher: fetcher, system: store)

    let prepared = await provisioner.prepare(.appleSpeech, preferences: ModelPreferences(defaults: defaults))

    #expect(prepared == .ready(.system(.speech, Locale(identifier: "pl_PL"))))
    #expect(store.installs == ["speech pl_PL"])
    #expect(defaults.string(forKey: ModelPreferences.activeKey) == ModelID.whisperTurbo.rawValue)
    #expect(defaults.string(forKey: ModelPreferences.localeKey(.speech)) == "pl_PL")
    #expect(fetcher.fetched.isEmpty)
  }

  @Test func `preparing a missing hosted model downloads nothing`() async {
    let fetcher = FakeFetcher()
    let provisioner = Provisioner(folder: folder, fetcher: fetcher, system: NoSystemModels())

    let prepared = await provisioner.prepare(.parakeetV3, preferences: ModelPreferences(defaults: defaults))

    #expect(prepared == .notInstalled)
    #expect(fetcher.fetched.isEmpty)
  }

  @Test func `preparing a model this Mac can't run installs nothing`() async {
    let provisioner = Provisioner(folder: folder, fetcher: FakeFetcher(), system: NoSystemModels())

    let prepared = await provisioner.prepare(.appleSpeech, preferences: ModelPreferences(defaults: defaults))

    #expect(prepared == .unavailable)
  }

  @Test func `preparing an installed hosted model is ready to load`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.whisperTurbo, in: folder)
    let provisioner = Provisioner(folder: folder, fetcher: FakeFetcher(), system: NoSystemModels())

    let prepared = await provisioner.prepare(.whisperTurbo, preferences: ModelPreferences(defaults: defaults))

    #expect(prepared == .ready(.hosted(.whisperTurbo)))
  }
}
