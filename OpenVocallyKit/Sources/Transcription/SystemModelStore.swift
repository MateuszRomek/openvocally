import Foundation
import Models

/// The speech assets macOS installs. The app uses the Speech framework; tests use a fake.
public protocol SystemModelStore: Sendable {
  /// Whether this Mac can run `model` at all.
  func isAvailable(_ model: SystemModel) -> Bool
  func supportedLocales(_ model: SystemModel) async -> [Locale]
  func isInstalled(_ model: SystemModel, locale: Locale) async -> Bool
  /// Reserves `locale` for the app, so macOS keeps its files, then installs it. Cancel by
  /// cancelling the calling task.
  func install(
    _ model: SystemModel, locale: Locale, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(SystemInstallError)
  /// Gives up the app's reservation of `locale`, so macOS may remove its files.
  func release(_ locale: Locale) async
}

public enum SystemInstallError: Error, Equatable, Sendable {
  case cancelled
  case offline
  case diskFull
  /// macOS keeps speech files for a limited number of languages per app, and every one is taken.
  case reservationLimit
  /// An AssetInventory error with no case of its own yet. Its domain and code are logged.
  case failed(domain: String, code: Int)
  /// This Mac has no speech models, such as on macOS 15.
  case unavailable
}

/// The store on a Mac without speech models: it offers none, so nothing installs through it.
struct NoSystemModels: SystemModelStore {
  func isAvailable(_ model: SystemModel) -> Bool { false }
  func supportedLocales(_ model: SystemModel) async -> [Locale] { [] }
  func isInstalled(_ model: SystemModel, locale: Locale) async -> Bool { false }
  func install(
    _ model: SystemModel, locale: Locale, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(SystemInstallError) {
    throw .unavailable
  }
  func release(_ locale: Locale) async {}
}

/// Why an install failed. The case names who failed, so the copy never asks what kind of model
/// it was.
public enum InstallError: Error, Equatable, Sendable {
  case download(DownloadError)
  case system(SystemInstallError)

  var isCancelled: Bool {
    switch self {
    case .download(.cancelled), .system(.cancelled): true
    case .download, .system: false
    }
  }
}

extension InstallError: CustomStringConvertible {
  /// The case alone, as diagnostics list download failures.
  public var description: String {
    switch self {
    case .download(let error): String(describing: error)
    case .system(let error): String(describing: error)
    }
  }
}

/// The language a system model starts with: the user's first preferred language it supports.
enum LocaleChoice {
  /// The region a language without one takes, both for a model's first language and for the
  /// languages a picker suggests, so the two agree.
  static var region: Locale.Region? { Locale.current.region }

  static func initial(supported: [Locale], preferred: [String], region: Locale.Region?) -> Locale? {
    for identifier in preferred {
      let wanted = Locale(identifier: identifier)
      if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }) {
        return exact
      }
      let sameLanguage = supported.filter { $0.language.languageCode == wanted.language.languageCode }
      let region = wanted.region ?? region
      // English set to Poland has no en_PL, so take the language's own likely region, en_US,
      // rather than whichever English sorts first.
      let language = Locale.Language(
        languageCode: wanted.language.languageCode, script: wanted.language.script)
      let likely = Locale(identifier: language.maximalIdentifier).region
      if let match = sameLanguage.first(where: { $0.region == region })
        ?? sameLanguage.first(where: { $0.region == likely }) ?? sameLanguage.first
      {
        return match
      }
    }
    return nil
  }
}
