import Foundation
import ModelsTestSupport
import Synchronization
import Testing

@testable import Models
@testable import Transcription

final class SlowSystemModels: SystemModelStore {
  let installs = Gate()
  private let installed = Mutex<Set<String>>([])

  func isAvailable(_ model: SystemModel) -> Bool { true }

  func supportedLocales(_ model: SystemModel) async -> [Locale] { [Locale(identifier: "de_DE")] }

  func isInstalled(_ model: SystemModel, locale: Locale) async -> Bool {
    installed.withLock { $0.contains("\(model.rawValue) \(locale.identifier)") }
  }

  func install(
    _ model: SystemModel, locale: Locale, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(SystemInstallError) {
    await installs.wait()
    _ = installed.withLock { $0.insert("\(model.rawValue) \(locale.identifier)") }
  }

  func release(_ locale: Locale) async {}
}

final class SlowChecks: Sendable {
  let slowCheck = Gate()
  private let holding = Mutex(false)

  func hold() { holding.withLock { $0 = true } }

  func inspect(_ model: HostedModel, in folder: ModelFolder) async -> Bool {
    let holds = holding.withLock { holding in
      defer { holding = false }
      return holding
    }
    if holds { await slowCheck.wait() }
    return folder.isInstalled(model)
  }
}

@MainActor struct OverlappingOperationsTests {
  let folder = Fixture.folder()
  let defaults: UserDefaults
  let log = LoadLog()

  init() throws {
    let suite = "OverlappingOperationsTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  @Test func `a delete that finishes after an install does not hide the installed model`() async throws {
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try Fixture.install(.parakeetV3, in: folder)
    try Fixture.install(.whisperTurbo, in: folder)
    let store = SlowSystemModels()
    let checks = SlowChecks()
    for model in [SystemModel.dictation, .speech] {
      defaults.set("de_DE", forKey: ModelPreferences.localeKey(model))
    }
    let log = log
    let folder = folder
    let runtime = TranscriptionRuntime(
      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
      load: { (model) throws(TranscriptionError) in try log.load(model) })
    let library = ModelLibrary(
      provisioner: Provisioner(folder: folder, fetcher: FakeFetcher(), system: store) { model in
        await checks.inspect(model, in: folder)
      },
      runtime: runtime, preferences: ModelPreferences(defaults: defaults))
    await library.start()

    library.install(.appleSpeech)
    checks.hold()
    let deleting = Task { try await library.remove(.whisperTurbo) }
    await eventually { checks.slowCheck.isWaiting }
    #expect(checks.slowCheck.isWaiting)

    store.installs.open()
    await eventually { !library.isInstalling && library.state(of: .appleSpeech).readiness == .installed }
    #expect(library.state(of: .appleSpeech).readiness == .installed)

    checks.slowCheck.open()
    try await deleting.value
    #expect(library.state(of: .whisperTurbo).readiness == .notInstalled)
    #expect(
      library.state(of: .appleSpeech).readiness == .installed,
      "the delete's older check must not undo the finished install")
  }
}

/// Speech assets installed in every language, whose next status query after `hold` waits for
/// `slowQuery` to open.
final class SlowLanguageChecks: SystemModelStore {
  let slowQuery = Gate()
  private let state = Mutex<(holding: Bool, releases: [String])>((false, []))

  var releases: [String] { state.withLock { $0.releases } }

  func hold() { state.withLock { $0.holding = true } }

  /// Only Speech, so no other model holds a language this test releases.
  func isAvailable(_ model: SystemModel) -> Bool { model == .speech }

  func supportedLocales(_ model: SystemModel) async -> [Locale] {
    [Locale(identifier: "de_DE"), Locale(identifier: "pl_PL")]
  }

  func isInstalled(_ model: SystemModel, locale: Locale) async -> Bool {
    let holds = state.withLock { state in
      defer { state.holding = false }
      return state.holding
    }
    if holds { await slowQuery.wait() }
    return true
  }

  func install(
    _ model: SystemModel, locale: Locale, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(SystemInstallError) {}

  func release(_ locale: Locale) async {
    state.withLock { $0.releases.append(locale.identifier) }
  }
}

@MainActor struct OverlappingLanguageChangeTests {
  let folder = Fixture.folder()
  let defaults: UserDefaults
  let loads = RuntimeLoads()

  init() throws {
    let suite = "OverlappingLanguageChangeTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  @Test func `switching a language away and back keeps the language in use reserved`() async {
    let store = SlowLanguageChecks()
    let german = Locale(identifier: "de_DE")
    defaults.set(ModelID.appleSpeech.rawValue, forKey: ModelPreferences.activeKey)
    defaults.set("de_DE", forKey: ModelPreferences.localeKey(.speech))
    let loads = loads
    let runtime = TranscriptionRuntime(
      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
      load: { (model) throws(TranscriptionError) in try loads.load(model) })
    let library = ModelLibrary(
      provisioner: Provisioner(folder: folder, fetcher: FakeFetcher(), system: store), runtime: runtime,
      preferences: ModelPreferences(defaults: defaults))
    await library.start()
    #expect(loads.all.last == .system(.speech, german))

    store.hold()
    let away = Task { await library.chooseLanguage(Locale(identifier: "pl_PL"), for: .appleSpeech) }
    await eventually { store.slowQuery.isWaiting }
    await library.chooseLanguage(german, for: .appleSpeech)
    store.slowQuery.open()
    await away.value

    let state = library.state(of: .appleSpeech)
    #expect(state.language?.chosen == german)
    #expect(state.readiness == .installed)
    #expect(loads.all.last == .system(.speech, german))
    #expect(store.releases == ["pl_PL"], "the slow switch away must not release German")
  }
}
