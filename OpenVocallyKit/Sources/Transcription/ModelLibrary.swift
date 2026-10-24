import Foundation
import Models
import Observation

/// Everything a screen shows or offers for one model, derived on read so it can't go stale.
public struct ModelState: Equatable, Sendable {
  public enum Readiness: Equatable, Sendable {
    case checking
    case notInstalled
    case installing(DownloadProgress)
    case installed
  }

  public let id: ModelID
  public let readiness: Readiness
  /// The files are on disk, also while they are replaced or checked.
  public let isOnDisk: Bool
  public let isActive: Bool
  public let failure: InstallError?
  /// Nil for a model that detects the language itself.
  public let language: LanguageSetting?
  /// The files to show in Finder. Nil when macOS owns them.
  public let files: URL?
  /// The bytes OpenVocally downloads. Nil for a model macOS installs.
  public let downloadSize: Int64?
  public let canRemove: Bool
  public let languageCount: Int
  public let recovery: Recovery
  /// Why an install can't start now, if it can't.
  public let installBlocker: InstallBlocker?
}

public struct LanguageSetting: Equatable, Sendable {
  public let supported: [Locale]
  public let chosen: Locale?
  /// The install is for the language shown, so it can't change until the install ends.
  public let canChange: Bool
}

public enum InstallBlocker: Equatable, Sendable {
  case anotherInstall
  case needsLanguage
}

/// What brings back the active model when it won't load.
public enum Recovery: Sendable, Equatable {
  case downloadAgain
  case tryAgain
}

public enum RemoveError: Error, Equatable, Sendable {
  case noReplacement
  case installing
  case notRemovable
  case fileSystem
}

/// The models this Mac offers, the active one, and the work on each. It is the only writer of
/// the stored preferences and of the model the runtime holds.
@MainActor @Observable public final class ModelLibrary {
  public private(set) var active: ModelID
  public private(set) var runtime: RuntimeState = .loading
  private var states: ModelStates
  /// The models this Mac can run, in catalog order.
  @ObservationIgnored private let offered: [ModelID]

  @ObservationIgnored private let provisioner: Provisioner
  @ObservationIgnored private let transcription: TranscriptionRuntime
  @ObservationIgnored private let preferences: ModelPreferences
  @ObservationIgnored private var installTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var phase = LibraryPhase.running
  /// Repeating it would load again after a failed load.
  @ObservationIgnored private var lastIntent: RuntimeIntent?
  @ObservationIgnored private var nextIntent: RuntimeIntent?
  @ObservationIgnored private var drain: Task<Void, Never>?
  /// The runtime's state stream outlives the library, so its reader stops only when cancelled.
  @ObservationIgnored private var stateTask: Task<Void, Never>?

  public init(provisioner: Provisioner, runtime: TranscriptionRuntime, preferences: ModelPreferences) {
    self.provisioner = provisioner
    self.transcription = runtime
    self.preferences = preferences
    active = preferences.active ?? .preferred
    let offered = provisioner.offered
    self.offered = offered
    states = ModelStates(
      Dictionary(
        uniqueKeysWithValues: offered.map { model in
          let resolved = provisioner.resolve(model, preferences: preferences, languages: [])
          return (model, ModelStates.Entry(resolved: resolved))
        }))
  }

  isolated deinit {
    stateTask?.cancel()
  }

  /// The region a language without one takes, both for a model's first language and for the
  /// languages a picker suggests, so the two agree.
  public static var region: Locale.Region? { LocaleChoice.region }

  /// Engines with at least one model this Mac can run.
  public var engines: [Engine] {
    Engine.allCases.filter { !models(of: $0).isEmpty }
  }

  public func models(of engine: Engine) -> [ModelID] {
    offered.filter { $0.engine == engine }
  }

  /// Models on disk now, in catalog order, including one being replaced.
  public var installedModels: [ModelID] {
    offered.filter { states[$0].presence == .present }
  }

  public var isInstalling: Bool { states.installing != nil }

  public func state(of model: ModelID) -> ModelState {
    let entry = states[model]
    let isActive = model == active
    let readiness: ModelState.Readiness =
      switch entry.slot?.work {
      case .installing(let progress, _)?: .installing(progress)
      case .checking?, .removing?: .checking
      case nil:
        switch entry.presence {
        case .unknown: .checking
        case .absent: .notInstalled
        case .present: .installed
        }
      }
    var blocker: InstallBlocker?
    if let installing = states.installing, installing != model {
      blocker = .anotherInstall
    } else if entry.resolved == nil {
      blocker = .needsLanguage
    }
    switch model.provider {
    case .hosted(let hosted):
      return ModelState(
        id: model, readiness: readiness, isOnDisk: entry.presence == .present, isActive: isActive,
        failure: entry.failure, language: nil, files: provisioner.folder.location(of: hosted),
        downloadSize: provisioner.downloadSize(hosted),
        canRemove: entry.isReady && (!isActive || replacement(for: model) != nil),
        languageCount: hosted.engine.languageCount, recovery: .downloadAgain, installBlocker: blocker)
    case .system:
      let language = LanguageSetting(
        supported: entry.languages, chosen: Self.locale(of: entry.resolved),
        canChange: Self.canRelocate(entry))
      return ModelState(
        id: model, readiness: readiness, isOnDisk: entry.presence == .present, isActive: isActive,
        failure: entry.failure, language: language, files: nil, downloadSize: nil, canRemove: false,
        languageCount: entry.languages.count, recovery: .tryAgain, installBlocker: blocker)
    }
  }

  /// Sweeps old downloads, checks what is installed and loads the active model. A hosted active
  /// model needs nothing from macOS, so it loads before the speech assets answer.
  public func start() async {
    guard !started else { return }
    started = true
    phase = .launching
    let transcription = transcription
    stateTask = Task { [weak self] in
      for await state in transcription.states { self?.runtime = state }
    }
    await provisioner.sweepStaleDownloads()
    await check(
      offered.compactMap { model in
        guard let resolved = states[model].resolved, case .hosted = resolved else { return nil }
        return states.begin(.check, on: model).map { ($0, resolved) }
      })
    await check(await languagesLoaded())
    phase = .running
    if states[active].presence != .present, !staysActiveWhenMissing(active),
      let replacement = replacement(for: active)
    {
      choose(replacement)
    }
    reconcile()
    await drain?.value
  }

  public func select(_ model: ModelID) {
    guard model != active, states[model].isReady else { return }
    choose(model)
    reconcile()
  }

  /// The model that takes over when `model` is removed: the preferred one first, then the
  /// catalog order.
  public func replacement(for model: ModelID) -> ModelID? {
    ([ModelID.preferred] + offered).first { $0 != model && states[$0].isReady }
  }

  /// Installs `model` in its current language. One install runs at a time.
  public func install(_ model: ModelID) {
    install(model, replacing: false)
  }

  public func cancelInstall() {
    installTask?.cancel()
  }

  /// Brings back a model that is installed but won't load, which can't be removed when it is
  /// the only one.
  public func recover(_ model: ModelID) async {
    switch state(of: model).recovery {
    case .downloadAgain:
      install(model, replacing: true)
    case .tryAgain:
      guard let resolved = states[model].resolved, let token = states.begin(.check, on: model) else { return }
      let present = await provisioner.isInstalled(resolved)
      guard states.finishCheck(token, present: present) else { return }
      guard present else {
        reconcile()
        return install(model)
      }
      reload(model)
    }
  }

  public func remove(_ model: ModelID) async throws(RemoveError) {
    guard case .hosted(let hosted) = model.provider else { throw .notRemovable }
    if case .installing? = states[model].slot?.work { throw .installing }
    guard states[model].isReady else { throw .notRemovable }
    if model == active {
      guard let replacement = replacement(for: model) else { throw .noReplacement }
      select(replacement)
    }
    guard let token = states.begin(.remove, on: model) else { throw .notRemovable }
    let removed = (try? await provisioner.remove(hosted)) != nil
    let present = await provisioner.isInstalled(.hosted(hosted))
    states.finishRemove(token, present: present)
    reconcile()
    guard removed else { throw .fileSystem }
  }

  /// Stores the pick, even one that matches the language the model already had, so it stays when
  /// the user's preferred languages change. The active model loads in the new language, and
  /// starts installing it when macOS doesn't have it yet.
  public func chooseLanguage(_ locale: Locale, for model: ModelID) async {
    guard case .system(let system) = model.provider, Self.canRelocate(states[model]) else { return }
    preferences.setLocale(locale, for: system)
    let previous = Self.locale(of: states[model].resolved)
    guard locale != previous, let token = states.relocate(model, to: .system(system, locale)) else { return }
    let present = await provisioner.isInstalled(.system(system, locale))
    guard states.finishCheck(token, present: present) else { return }
    reconcile()
    // Released only once this pick has won, so a quick switch back doesn't give up the language
    // it switched back to.
    if let previous, !usesLocale(previous) { await provisioner.release(previous) }
    if model == active, !present { install(model) }
  }

  private func install(_ model: ModelID, replacing: Bool) {
    guard let resolved = states[model].resolved,
      let token = states.begin(.install(replacing: replacing, from: firstProgress(resolved)), on: model)
    else { return }
    reconcile()
    let (updates, sink) = AsyncStream.makeStream(
      of: DownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
    Task {
      for await progress in updates { report(progress, token) }
    }
    let provisioner = provisioner
    installTask = Task {
      let result: Result<Void, InstallError>
      do throws(InstallError) {
        try await provisioner.install(resolved, replacing: replacing) { sink.yield($0) }
        result = .success(())
      } catch {
        result = .failure(error)
      }
      sink.finish()
      let present = await provisioner.isInstalled(resolved)
      finishInstall(model, resolved, token, result, present: present)
    }
  }

  private func firstProgress(_ model: ResolvedModel) -> DownloadProgress {
    switch model {
    case .hosted(let hosted): .downloading(received: 0, total: provisioner.downloadSize(hosted))
    case .system: .indeterminate
    }
  }

  private func report(_ progress: DownloadProgress, _ token: ModelStates.Token) {
    var next = states
    guard next.progress(progress, token) else { return }
    states = next
  }

  private func finishInstall(
    _ model: ModelID, _ resolved: ResolvedModel, _ token: ModelStates.Token,
    _ result: Result<Void, InstallError>, present: Bool
  ) {
    installTask = nil
    guard states.finishInstall(token, result, present: present) else { return }
    guard case .success = result, present else { return reconcile() }
    if case .system(let system, let locale) = resolved { preferences.setLocale(locale, for: system) }
    if model == active || states[active].presence == .absent { choose(model) }
    reload(model)
  }

  private func languagesLoaded() async -> [(ModelStates.Token, ResolvedModel)] {
    let provisioner = provisioner
    let systems = offered.compactMap { model -> SystemModel? in
      guard case .system(let system) = model.provider else { return nil }
      return system
    }
    let supported = await withTaskGroup(of: (SystemModel, [Locale]).self) { group in
      for system in systems {
        group.addTask { (system, await provisioner.languages(of: system)) }
      }
      var supported: [(SystemModel, [Locale])] = []
      for await languages in group { supported.append(languages) }
      return supported
    }
    return supported.compactMap { system, languages in
      states.list(languages, for: system.id)
      let resolved = provisioner.resolve(system.id, preferences: preferences, languages: languages)
      return states.relocate(system.id, to: resolved).flatMap { token in resolved.map { (token, $0) } }
    }
  }

  private func check(_ checks: [(ModelStates.Token, ResolvedModel)]) async {
    let provisioner = provisioner
    await withTaskGroup(of: (ModelStates.Token, Bool).self) { group in
      for (token, model) in checks {
        group.addTask { (token, await provisioner.isInstalled(model)) }
      }
      for await (token, present) in group {
        states.finishCheck(token, present: present)
        reconcile()
      }
    }
  }

  private func choose(_ model: ModelID) {
    active = model
    preferences.setActive(model)
  }

  private func usesLocale(_ locale: Locale) -> Bool {
    offered.contains { Self.locale(of: states[$0].resolved) == locale }
  }

  /// Loads `model` again if it is active, even when the runtime already holds it, as after a
  /// failed load or a replace.
  private func reload(_ model: ModelID) {
    if model == active { lastIntent = nil }
    reconcile()
  }

  private func reconcile() {
    let intent = RuntimeIntent.of(states[active], phase: phase)
    switch intent {
    case .keep: return
    case .load, .unload: guard intent != lastIntent else { return }
    }
    lastIntent = intent
    nextIntent = intent
    guard drain == nil else { return }
    let transcription = transcription
    drain = Task {
      while let next = nextIntent {
        nextIntent = nil
        switch next {
        case .keep: break
        case .load(let model): await transcription.activate(model)
        case .unload: await transcription.activate(nil)
        }
      }
      drain = nil
    }
  }

  /// A system model macOS removed, or that isn't installed in its language, stays active so its
  /// row offers the install instead of dictation moving to another model.
  private func staysActiveWhenMissing(_ model: ModelID) -> Bool {
    switch model.provider {
    case .hosted: false
    case .system: offered.contains(model)
    }
  }

  private static func locale(of model: ResolvedModel?) -> Locale? {
    switch model {
    case .system(_, let locale)?: locale
    case .hosted?, nil: nil
    }
  }

  private static func canRelocate(_ entry: ModelStates.Entry) -> Bool {
    switch entry.slot?.work {
    case .installing?, .removing?: false
    case .checking?, nil: true
    }
  }
}
