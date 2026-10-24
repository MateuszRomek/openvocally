import Foundation
import Models

/// Checks, installs and removes models: hosted files in the local-models folder, system models
/// through macOS. It keeps no state of its own apart from the downloader's one download at a
/// time; what the screens show lives in the model library.
public struct Provisioner: Sendable {
  let folder: ModelFolder
  let downloader: ModelDownloader
  let system: any SystemModelStore
  let inspect: @Sendable (HostedModel) async -> Bool

  public init(folder: ModelFolder, fetcher: any ModelFetching, system: any SystemModelStore) {
    self.init(folder: folder, fetcher: fetcher, system: system) { model in await Self.stat(model, in: folder)
    }
  }

  init(
    folder: ModelFolder, fetcher: any ModelFetching, system: any SystemModelStore,
    inspect: @escaping @Sendable (HostedModel) async -> Bool
  ) {
    self.folder = folder
    self.downloader = ModelDownloader(folder: folder, fetcher: fetcher)
    self.system = system
    self.inspect = inspect
  }

  public enum Preparation: Equatable, Sendable {
    case ready(ResolvedModel)
    case notInstalled
    /// This Mac can't run the model.
    case unavailable
    case needsLanguage
    case failed(InstallError)
  }

  /// Gets `model` ready to load without the model library, in its stored language. A missing
  /// system model is installed, which for a language macOS already has only reserves it for this
  /// app; a missing hosted model is not downloaded. Writes no preference.
  public func prepare(_ model: ModelID, preferences: ModelPreferences) async -> Preparation {
    guard offered.contains(model) else { return .unavailable }
    let languages =
      switch model.provider {
      case .hosted: [Locale]()
      case .system(let system): await languages(of: system)
      }
    guard let resolved = resolve(model, preferences: preferences, languages: languages) else {
      return .needsLanguage
    }
    if await isInstalled(resolved) { return .ready(resolved) }
    switch resolved {
    case .hosted: return .notInstalled
    case .system:
      do throws(InstallError) {
        try await install(resolved, replacing: false) { _ in }
      } catch {
        return .failed(error)
      }
      return await isInstalled(resolved) ? .ready(resolved) : .notInstalled
    }
  }

  var offered: [ModelID] {
    ModelID.allCases.filter { model in
      switch model.provider {
      case .hosted: true
      case .system(let model): system.isAvailable(model)
      }
    }
  }

  func languages(of model: SystemModel) async -> [Locale] {
    let names = Locale.current
    return await system.supportedLocales(model).sorted {
      (names.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
        .localizedStandardCompare(names.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        == .orderedAscending
    }
  }

  func resolve(_ model: ModelID, preferences: ModelPreferences, languages: [Locale]) -> ResolvedModel? {
    switch model.provider {
    case .hosted(let hosted): return .hosted(hosted)
    case .system(let system):
      let stored = preferences.locale(for: system)
      let locale =
        languages.first { $0.identifier == stored }
        ?? LocaleChoice.initial(
          supported: languages, preferred: Locale.preferredLanguages, region: LocaleChoice.region)
      return locale.map { .system(system, $0) }
    }
  }

  func isInstalled(_ model: ResolvedModel) async -> Bool {
    switch model {
    case .hosted(let hosted): await inspect(hosted)
    case .system(let model, let locale): await system.isInstalled(model, locale: locale)
    }
  }

  func install(
    _ model: ResolvedModel, replacing: Bool, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(InstallError) {
    switch model {
    case .hosted(let hosted):
      do throws(DownloadError) {
        try await downloader.install(hosted, replacing: replacing, progress: progress)
      } catch {
        throw .download(error)
      }
    case .system(let model, let locale):
      do throws(SystemInstallError) {
        try await system.install(model, locale: locale, progress: progress)
      } catch {
        throw .system(error)
      }
    }
  }

  func remove(_ model: HostedModel) async throws {
    try await Self.delete(model, in: folder)
  }

  func release(_ locale: Locale) async {
    await system.release(locale)
  }

  func downloadSize(_ model: HostedModel) -> Int64 {
    folder.manifest(of: model).totalBytes
  }

  @concurrent func sweepStaleDownloads() async {
    folder.sweepStaleDownloads()
  }

  @concurrent private static func stat(_ model: HostedModel, in folder: ModelFolder) async -> Bool {
    folder.isInstalled(model)
  }

  @concurrent private static func delete(_ model: HostedModel, in folder: ModelFolder) async throws {
    try folder.delete(model)
  }
}
