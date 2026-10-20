import Foundation
import ModelsTestSupport
import Synchronization
import Testing

@testable import Models
@testable import Transcription

/// Speech assets in memory: which models run here, their languages, and what is installed.
final class FakeSystemModels: SystemModelStore {
  private let state = Mutex<(installed: Set<String>, installs: [String], releases: [String])>(([], [], []))
  let available: Set<SystemModel>
  let locales: [Locale]
  /// Shut, `supportedLocales` waits for it.
  let languages: Gate?
  /// Set, an install reports no size and waits until it is cancelled.
  let holdsInstalls: Bool

  init(
    available: Set<SystemModel>, locales: [String] = ["en_US", "pl_PL", "de_DE"], languages: Gate? = nil,
    holdsInstalls: Bool = false
  ) {
    self.available = available
    self.locales = locales.map(Locale.init(identifier:))
    self.languages = languages
    self.holdsInstalls = holdsInstalls
  }

  var installs: [String] { state.withLock { $0.installs } }
  var releases: [String] { state.withLock { $0.releases } }

  func isAvailable(_ model: SystemModel) -> Bool { available.contains(model) }

  func supportedLocales(_ model: SystemModel) async -> [Locale] {
    await languages?.wait()
    return locales
  }

  func isInstalled(_ model: SystemModel, locale: Locale) async -> Bool {
    state.withLock { $0.installed.contains("\(model.rawValue) \(locale.identifier)") }
  }

  func install(
    _ model: SystemModel, locale: Locale, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(DownloadError) {
    let key = "\(model.rawValue) \(locale.identifier)"
    if holdsInstalls {
      progress(.indeterminate)
      try? await Task.sleep(for: .seconds(3600))
      throw .cancelled
    }
    progress(.downloading(received: 50, total: 100))
    state.withLock {
      $0.installs.append(key)
      $0.installed.insert(key)
    }
  }

  func release(_ locale: Locale) async {
    state.withLock { $0.releases.append(locale.identifier) }
  }

  func preinstall(_ model: SystemModel, _ locale: String) {
    _ = state.withLock { $0.installed.insert("\(model.rawValue) \(locale)") }
  }
}

final class RuntimeLoads: Sendable {
  private let state = Mutex<(loads: [RuntimeModel], failing: Bool)>(([], false))
  var all: [RuntimeModel] { state.withLock { $0.loads } }
  func fail(_ failing: Bool) { state.withLock { $0.failing = failing } }

  func load(_ model: RuntimeModel) throws(TranscriptionError) -> any Transcriber {
    let failing = state.withLock { state in
      state.loads.append(model)
      return state.failing
    }
    if failing { throw .engineFailed }
    return FakeTranscriber()
  }
}

@MainActor struct SystemModelLibraryTests {
  let folder = Fixture.folder()
  let defaults: UserDefaults
  let loads = RuntimeLoads()

  init() throws {
    let suite = "SystemModelLibraryTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  func library(_ store: FakeSystemModels?) -> ModelLibrary {
    let loads = loads
    let runtime = TranscriptionRuntime(
      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
      load: { (model) throws(TranscriptionError) in try loads.load(model) })
    return ModelLibrary(
      folder: folder, downloader: ModelDownloader(folder: folder, fetcher: FakeFetcher()), runtime: runtime,
      systemModels: store, defaults: defaults)
  }

  @Test func `a system model this Mac can't run is not offered`() async {
    let library = library(FakeSystemModels(available: [.dictation]))
    await library.start()
    #expect(library.models(of: .apple) == [.appleDictation])

    let without = self.library(nil)
    await without.start()
    #expect(!without.engines.contains(.apple))
    #expect(without.engines == [.parakeet, .whisper])
  }

  @Test func `a system model is installed only in its chosen language`() async {
    let store = FakeSystemModels(available: [.dictation, .speech])
    store.preinstall(.dictation, "pl_PL")
    defaults.set("de_DE", forKey: ModelLibrary.localeKey(.appleDictation))
    let library = library(store)
    await library.start()
    #expect(!library.installed.contains(.appleDictation))

    await library.chooseLanguage(Locale(identifier: "pl_PL"), for: .appleDictation)
    #expect(library.locale(of: .appleDictation)?.identifier == "pl_PL")
    #expect(library.installed.contains(.appleDictation))
  }

  @Test func `choosing a language for the active model loads it in that language`() async {
    let store = FakeSystemModels(available: [.dictation])
    store.preinstall(.dictation, "en_US")
    store.preinstall(.dictation, "pl_PL")
    defaults.set(ModelID.appleDictation.rawValue, forKey: ModelLibrary.activeKey)
    defaults.set("en_US", forKey: ModelLibrary.localeKey(.appleDictation))
    let library = library(store)
    await library.start()
    await eventually { library.runtime == .ready }

    await library.chooseLanguage(Locale(identifier: "pl_PL"), for: .appleDictation)
    await eventually { loads.all.count == 2 }
    #expect(
      loads.all == [
        .system(.dictation, Locale(identifier: "en_US")), .system(.dictation, Locale(identifier: "pl_PL")),
      ])
  }

  @Test func `a system model installs through macOS and can't be deleted`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let store = FakeSystemModels(available: [.speech])
    defaults.set("de_DE", forKey: ModelLibrary.localeKey(.appleSpeech))
    try Fixture.install(.parakeetV3, in: folder)
    let library = library(store)
    await library.start()

    library.startDownload(.appleSpeech)
    #expect(library.download?.model == .appleSpeech)
    await eventually { library.download == nil && library.installed.contains(.appleSpeech) }
    #expect(store.installs == ["speech de_DE"])
    #expect(library.installed == [.parakeetV3, .appleSpeech])
    await #expect(throws: ModelLibrary.DeleteError.systemManaged) { try await library.delete(.appleSpeech) }
  }

  @Test func `a system model that won't load tries again instead of downloading`() async {
    let store = FakeSystemModels(available: [.dictation])
    store.preinstall(.dictation, "en_US")
    defaults.set(ModelID.appleDictation.rawValue, forKey: ModelLibrary.activeKey)
    defaults.set("en_US", forKey: ModelLibrary.localeKey(.appleDictation))
    loads.fail(true)
    let library = library(store)
    await library.start()
    await eventually { library.runtime == .failed }
    #expect(library.recovery(for: .appleDictation) == .tryAgain)

    loads.fail(false)
    await library.recover(.appleDictation)
    await eventually { library.runtime == .ready }
    #expect(library.runtime == .ready)
    #expect(store.installs.isEmpty)
    #expect(loads.all.count == 2)
  }

  @Test func `trying again installs a language macOS removed`() async {
    let store = FakeSystemModels(available: [.dictation])
    store.preinstall(.dictation, "en_US")
    defaults.set(ModelID.appleDictation.rawValue, forKey: ModelLibrary.activeKey)
    defaults.set("pl_PL", forKey: ModelLibrary.localeKey(.appleDictation))
    let library = library(store)
    await library.start()
    await library.recover(.appleDictation)
    await eventually { library.runtime == .ready }
    #expect(store.installs == ["dictation pl_PL"])
  }

  @Test func `picking the language a model already has stores it`() async throws {
    let library = library(FakeSystemModels(available: [.dictation]))
    await library.start()
    let current = try #require(library.locale(of: .appleDictation))
    #expect(defaults.string(forKey: ModelLibrary.localeKey(.appleDictation)) == nil)

    await library.chooseLanguage(current, for: .appleDictation)
    #expect(defaults.string(forKey: ModelLibrary.localeKey(.appleDictation)) == current.identifier)
  }

  @Test func `installing a system model stores the language it installed`() async throws {
    let store = FakeSystemModels(available: [.dictation])
    let library = library(store)
    await library.start()
    let current = try #require(library.locale(of: .appleDictation))

    library.startDownload(.appleDictation)
    await eventually { library.download == nil }
    #expect(store.installs == ["dictation \(current.identifier)"])
    #expect(defaults.string(forKey: ModelLibrary.localeKey(.appleDictation)) == current.identifier)
  }

  @Test func `an active system model missing its language stays active`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    defaults.set(ModelID.appleDictation.rawValue, forKey: ModelLibrary.activeKey)
    defaults.set("de_DE", forKey: ModelLibrary.localeKey(.appleDictation))
    let library = library(FakeSystemModels(available: [.dictation]))
    await library.start()
    await eventually { library.runtime == .notInstalled }
    #expect(library.active == .appleDictation)
    #expect(library.runtime == .notInstalled)
    #expect(loads.all.isEmpty)
  }

  @Test func `a new language for the active model installs, then loads`() async {
    let store = FakeSystemModels(available: [.dictation])
    store.preinstall(.dictation, "en_US")
    defaults.set(ModelID.appleDictation.rawValue, forKey: ModelLibrary.activeKey)
    defaults.set("en_US", forKey: ModelLibrary.localeKey(.appleDictation))
    let library = library(store)
    await library.start()
    await eventually { library.runtime == .ready }

    await library.chooseLanguage(Locale(identifier: "de_DE"), for: .appleDictation)
    #expect(library.download?.model == .appleDictation)
    #expect(library.download?.locale?.identifier == "de_DE")
    await eventually { library.download == nil && library.runtime == .ready && loads.all.count == 2 }
    #expect(store.installs == ["dictation de_DE"])
    #expect(loads.all.last == .system(.dictation, Locale(identifier: "de_DE")))
    #expect(library.active == .appleDictation)
  }

  @Test func `the language can't change while it installs`() async {
    let store = FakeSystemModels(available: [.dictation], holdsInstalls: true)
    defaults.set("pl_PL", forKey: ModelLibrary.localeKey(.appleDictation))
    let library = library(store)
    await library.start()
    library.startDownload(.appleDictation)
    await eventually { library.download?.progress == .indeterminate }
    #expect(library.download?.progress == .indeterminate)
    #expect(library.download?.fraction == nil)

    await library.chooseLanguage(Locale(identifier: "de_DE"), for: .appleDictation)
    #expect(library.locale(of: .appleDictation)?.identifier == "pl_PL")
    #expect(defaults.string(forKey: ModelLibrary.localeKey(.appleDictation)) == "pl_PL")
    library.cancelDownload()
    await eventually { library.download == nil }
  }

  @Test func `a replaced language is released unless the other model uses it`() async {
    let store = FakeSystemModels(available: [.dictation, .speech])
    defaults.set("en_US", forKey: ModelLibrary.localeKey(.appleDictation))
    defaults.set("en_US", forKey: ModelLibrary.localeKey(.appleSpeech))
    let library = library(store)
    await library.start()

    await library.chooseLanguage(Locale(identifier: "pl_PL"), for: .appleDictation)
    #expect(store.releases.isEmpty)
    await library.chooseLanguage(Locale(identifier: "de_DE"), for: .appleDictation)
    #expect(store.releases == ["pl_PL"])
  }

  @Test func `a downloaded model loads before the system languages answer`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    let languages = Gate()
    let library = library(FakeSystemModels(available: [.dictation], languages: languages))
    let starting = Task { await library.start() }
    await eventually { loads.all == [.downloaded(.parakeetV3)] }
    #expect(loads.all == [.downloaded(.parakeetV3)])
    #expect(library.languages(of: .appleDictation).isEmpty)

    languages.open()
    await starting.value
    #expect(library.languages(of: .appleDictation).count == 3)
    #expect(loads.all == [.downloaded(.parakeetV3)])
  }
}

struct LocaleChoiceTests {
  let supported = ["en_US", "en_GB", "pl_PL", "de_DE"].map(Locale.init(identifier:))

  func initial(_ preferred: [String], region: String? = nil) -> String? {
    LocaleChoice.initial(
      supported: supported, preferred: preferred, region: region.map { Locale.Region($0) })?.identifier
  }

  @Test func `the first preferred language the model supports wins`() {
    #expect(initial(["fr-FR", "pl-PL", "en-US"]) == "pl_PL")
    #expect(initial(["en-GB"]) == "en_GB")
  }

  @Test func `a language without a supported region takes the Mac's region, then the first`() {
    #expect(initial(["en"], region: "GB") == "en_GB")
    #expect(initial(["en-AU"]) == "en_US")
  }

  @Test func `a region the language isn't offered in takes the language's likely region`() {
    let supported = ["en_AE", "en_GB", "en_US", "pt_PT", "pt_BR"].map(Locale.init(identifier:))
    let choose = { LocaleChoice.initial(supported: supported, preferred: [$0], region: nil)?.identifier }
    #expect(choose("en-PL") == "en_US")
    #expect(choose("pt") == "pt_BR")
  }

  @Test func `no supported preferred language chooses nothing`() {
    #expect(initial(["fr-FR", "ja-JP"]) == nil)
  }
}
