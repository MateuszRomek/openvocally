import Foundation
import Models
import Observation

/// What the Models screen shows and does: installed models, the active one, the download in
/// progress and the last failure per model.
@MainActor @Observable public final class ModelLibrary {
  public struct Download: Equatable, Sendable {
    public let model: ModelID
    /// The language a system model installs in, so the install is judged by it even if the
    /// model's language changes meanwhile. Nil for a downloaded model.
    public let locale: Locale?
    public var progress: DownloadProgress

    /// 0 to 1, or nil while the size is unknown or the files are verifying.
    public var fraction: Double? {
      guard case .downloading(let received, let total) = progress, total > 0 else { return nil }
      return Double(received) / Double(total)
    }
  }

  public enum DeleteError: Error, Equatable {
    /// The active model can go only when another installed model can take over.
    case noReplacement
    case downloading
    case fileSystem
    /// macOS installs and removes system models itself.
    case systemManaged
  }

  /// What brings back the active model when it won't load.
  public enum Recovery: Sendable, Equatable {
    /// Download its files again. The old ones stay until the new ones pass verification.
    case downloadAgain
    /// Load it again, installing its language first if macOS removed it.
    case tryAgain
  }

  public private(set) var installed: Set<ModelID> = []
  public private(set) var active: ModelID
  public private(set) var download: Download?
  public private(set) var failures: [ModelID: DownloadError] = [:]
  public private(set) var runtime: RuntimeState = .loading
  /// The models this Mac can run, in catalog order.
  private(set) var offered: [ModelID]
  /// The languages each system model supports, as this Mac reports them.
  private(set) var systemLanguages: [SystemModel: [Locale]] = [:]
  /// Each system model's language: the stored pick, else the user's first preferred language it
  /// supports. Nil for one with neither.
  private(set) var systemLocales: [ModelID: Locale] = [:]
  @ObservationIgnored private let systemModels: (any SystemModelStore)?

  @ObservationIgnored private let folder: ModelFolder
  @ObservationIgnored private let downloader: ModelDownloader
  @ObservationIgnored private let transcription: TranscriptionRuntime
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  /// The runtime's state stream outlives the library, so its reader stops only when cancelled.
  @ObservationIgnored private var stateTask: Task<Void, Never>?

  static let activeKey = "transcription.modelID"
  static func localeKey(_ model: ModelID) -> String { "transcription.locale.\(model.rawValue)" }

  /// Offers the downloadable models and the system models `systemModels` says this Mac can
  /// run. `systemModels` is nil where the system has no speech models, such as macOS 15.
  public init(
    folder: ModelFolder, downloader: ModelDownloader, runtime: TranscriptionRuntime,
    systemModels: (any SystemModelStore)? = nil, defaults: UserDefaults = .standard
  ) {
    self.folder = folder
    self.downloader = downloader
    self.transcription = runtime
    self.systemModels = systemModels
    self.defaults = defaults
    active = defaults.string(forKey: Self.activeKey).flatMap(ModelID.init) ?? .preferred
    offered = ModelID.allCases.filter { model in
      guard case .system(let system) = model.source else { return true }
      return systemModels?.isAvailable(system) ?? false
    }
  }

  isolated deinit {
    stateTask?.cancel()
  }

  /// Sweeps old downloads, reads what is installed and starts loading the active model.
  public func start() async {
    guard !started else { return }
    started = true
    let transcription = transcription
    stateTask = Task { [weak self] in
      for await state in transcription.states { self?.runtime = state }
    }
    let downloaded = await Self.sweepAndScan(folder)
    installed = downloaded
    // A downloaded model needs nothing from macOS, so it loads before the speech assets answer.
    let loadsEarly = active.downloadable != nil && downloaded.contains(active)
    if loadsEarly { await transcription.activate(runtimeModel(for: active)) }
    await loadSystemLanguages()
    installed = downloaded.union(await installedSystemModels())
    guard !loadsEarly else { return }
    // A system model that macOS removed, or that isn't installed in its language, stays active,
    // so its row offers the download instead of dictation moving to another model.
    let installable = active.downloadable == nil && offered.contains(active)
    if !installed.contains(active), !installable, let replacement = replacement(for: active) {
      choose(replacement)
    }
    await transcription.activate(installed.contains(active) ? runtimeModel(for: active) : nil)
  }

  /// Engines with at least one model this Mac can run.
  public var engines: [Engine] {
    Engine.allCases.filter { !models(of: $0).isEmpty }
  }

  public func models(of engine: Engine) -> [ModelID] {
    offered.filter { $0.engine == engine }
  }

  /// What the runtime loads for `model`, or nil for a system model with no language yet.
  public func runtimeModel(for model: ModelID) -> RuntimeModel? {
    switch model.source {
    case .huggingFace: .downloaded(model)
    case .system(let system): locale(of: model).map { .system(system, $0) }
    }
  }

  /// Nil for a model macOS installs: its files are not OpenVocally's to show.
  public func location(of model: ModelID) -> URL? {
    model.downloadable.map(folder.location)
  }

  func canSelect(_ model: ModelID) -> Bool {
    installed.contains(model)
  }

  public func select(_ model: ModelID) {
    guard canSelect(model), model != active else { return }
    choose(model)
    let transcription = transcription
    let loaded = runtimeModel(for: model)
    Task { await transcription.activate(loaded) }
  }

  /// The model that takes over when `model` is deleted: the preferred one first, then the
  /// catalog order.
  public func replacement(for model: ModelID) -> ModelID? {
    ([ModelID.preferred] + offered).first { $0 != model && canSelect($0) }
  }

  public func startDownload(_ model: ModelID) {
    guard !installed.contains(model) else { return }
    download(model, replacing: false)
  }

  private func download(_ model: ModelID, replacing: Bool) {
    guard download == nil, let install = installation(of: model, replacing: replacing) else { return }
    failures[model] = nil
    let started = Download(model: model, locale: install.locale, progress: install.start)
    download = started
    let (updates, sink) = AsyncStream.makeStream(
      of: DownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
    Task {
      for await progress in updates { report(progress, for: model) }
    }
    downloadTask = Task {
      var failure: DownloadError?
      do throws(DownloadError) {
        try await install.run { sink.yield($0) }
      } catch {
        failure = error
      }
      sink.finish()
      await finishDownload(started, error: failure)
    }
  }

  private struct Installation {
    var locale: Locale?
    let start: DownloadProgress
    let run: @Sendable (@escaping @Sendable (DownloadProgress) -> Void) async throws(DownloadError) -> Void
  }

  /// How `model` installs: OpenVocally's download, or macOS for a system model's chosen language.
  private func installation(of model: ModelID, replacing: Bool) -> Installation? {
    switch model.source {
    case .huggingFace(let manifest):
      guard let hosted = model.downloadable else { return nil }
      let downloader = downloader
      return Installation(start: .downloading(received: 0, total: manifest.totalBytes)) {
        (progress) throws(DownloadError) in
        try await downloader.install(hosted, replacing: replacing, progress: progress)
      }
    case .system(let system):
      guard !replacing, let store = systemModels, let locale = locale(of: model) else { return nil }
      return Installation(locale: locale, start: .indeterminate) { (progress) throws(DownloadError) in
        try await store.install(system, locale: locale, progress: progress)
      }
    }
  }

  public func recovery(for model: ModelID) -> Recovery {
    switch model.source {
    case .huggingFace: .downloadAgain
    case .system: .tryAgain
    }
  }

  /// Brings back a model that is installed but won't load, which can't be deleted when it is
  /// the only one.
  public func recover(_ model: ModelID) async {
    switch recovery(for: model) {
    case .downloadAgain:
      guard installed.contains(model) else { return }
      download(model, replacing: true)
    case .tryAgain:
      await rescan()
      guard installed.contains(model) else { return startDownload(model) }
      guard model == active else { return }
      await transcription.activate(runtimeModel(for: model))
    }
  }

  public func cancelDownload() {
    downloadTask?.cancel()
  }

  public func delete(_ model: ModelID) async throws(DeleteError) {
    if case .system = model.source { throw .systemManaged }
    guard download?.model != model else { throw .downloading }
    if model == active {
      guard let replacement = replacement(for: model) else { throw .noReplacement }
      select(replacement)
    }
    let deleted = await Self.delete(model, in: folder)
    await rescan()
    guard deleted else { throw .fileSystem }
  }

  private func choose(_ model: ModelID) {
    active = model
    defaults.set(model.rawValue, forKey: Self.activeKey)
  }

  /// Progress arrives for every network read, so only a whole-percent change, or a change of
  /// phase, redraws.
  private func report(_ progress: DownloadProgress, for model: ModelID) {
    guard var download, download.model == model else { return }
    let before = download
    download.progress = progress
    let percent = { (download: Download) in download.fraction.map { Int($0 * 100) } }
    let phaseChanged = download.fraction == nil && progress != before.progress
    guard percent(download) != percent(before) || phaseChanged else { return }
    self.download = download
  }

  private func finishDownload(_ finished: Download, error: DownloadError?) async {
    let model = finished.model
    download = nil
    downloadTask = nil
    if let error, error != .cancelled { failures[model] = error }
    let wasMissing = !installed.contains(active)
    if error == nil, let locale = finished.locale { await remember(locale, for: model) }
    await rescan()
    guard error == nil, installed.contains(model), model == active || wasMissing else { return }
    choose(model)
    await transcription.activate(runtimeModel(for: model))
  }

  private func rescan() async {
    let downloaded = await Self.scan(folder)
    installed = downloaded.union(await installedSystemModels())
  }

  /// System models installed for their chosen language. One with no language is not installed.
  private func installedSystemModels() async -> Set<ModelID> {
    guard let systemModels else { return [] }
    let asked = offered.compactMap { model -> (ModelID, SystemModel, Locale)? in
      guard case .system(let system) = model.source, let locale = locale(of: model) else { return nil }
      return (model, system, locale)
    }
    return await withTaskGroup(of: ModelID?.self) { group in
      for (model, system, locale) in asked {
        group.addTask { await systemModels.isInstalled(system, locale: locale) ? model : nil }
      }
      var found: Set<ModelID> = []
      for await model in group {
        if let model { found.insert(model) }
      }
      return found
    }
  }

  @concurrent private nonisolated static func sweepAndScan(_ folder: ModelFolder) async -> Set<ModelID> {
    folder.sweepStaleDownloads()
    return folder.installedModels()
  }

  @concurrent private nonisolated static func scan(_ folder: ModelFolder) async -> Set<ModelID> {
    folder.installedModels()
  }

  @concurrent private nonisolated static func delete(_ model: ModelID, in folder: ModelFolder) async -> Bool {
    guard let hosted = model.downloadable else { return false }
    return (try? folder.delete(hosted)) != nil
  }
}

extension ModelLibrary {
  /// The languages `model` transcribes, sorted by their names in the user's language. Empty for
  /// a model that detects the language itself.
  public func languages(of model: ModelID) -> [Locale] {
    guard case .system(let system) = model.source else { return [] }
    return systemLanguages[system] ?? []
  }

  /// The chosen language of a system model, else the user's first preferred language it supports.
  public func locale(of model: ModelID) -> Locale? {
    systemLocales[model]
  }

  /// The region a language without one takes, both for a model's first language and for the
  /// languages a picker suggests, so the two agree.
  public static var region: Locale.Region? { Locale.current.region }

  /// Stores the pick, even one that matches the language the model already had, so it stays when
  /// the user's preferred languages change. The active model loads in the new language, and
  /// starts installing it when macOS doesn't have it yet.
  public func chooseLanguage(_ locale: Locale, for model: ModelID) async {
    guard case .system = model.source, download?.model != model else { return }
    guard await remember(locale, for: model) else { return }
    await rescan()
    guard model == active else { return }
    guard installed.contains(model) else {
      await transcription.activate(nil)
      return startDownload(model)
    }
    await transcription.activate(runtimeModel(for: model))
  }

  /// Stores `locale` as `model`'s language and releases the language it replaces, unless the
  /// other system model still uses it. False when the language didn't change.
  @discardableResult
  private func remember(_ locale: Locale, for model: ModelID) async -> Bool {
    defaults.set(locale.identifier, forKey: Self.localeKey(model))
    let previous = systemLocales[model]
    guard locale != previous else { return false }
    systemLocales[model] = locale
    if let previous, !systemLocales.values.contains(previous) { await systemModels?.release(previous) }
    return true
  }

  fileprivate func loadSystemLanguages() async {
    guard let systemModels else { return }
    let systems = offered.compactMap { model -> (ModelID, SystemModel)? in
      guard case .system(let system) = model.source else { return nil }
      return (model, system)
    }
    let supported = await withTaskGroup(of: (ModelID, SystemModel, [Locale]).self) { group in
      for (model, system) in systems {
        group.addTask { (model, system, await systemModels.supportedLocales(system)) }
      }
      var supported: [(ModelID, SystemModel, [Locale])] = []
      for await languages in group { supported.append(languages) }
      return supported
    }
    let names = Locale.current
    for (model, system, locales) in supported {
      let sorted = locales.sorted {
        (names.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
          .localizedStandardCompare(names.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
          == .orderedAscending
      }
      systemLanguages[system] = sorted
      let stored = defaults.string(forKey: Self.localeKey(model))
      systemLocales[model] =
        sorted.first { $0.identifier == stored }
        ?? LocaleChoice.initial(supported: sorted, preferred: Locale.preferredLanguages, region: Self.region)
    }
  }
}
