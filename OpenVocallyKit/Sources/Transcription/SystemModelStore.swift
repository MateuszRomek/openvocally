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
  ) async throws(DownloadError)
  /// Gives up the app's reservation of `locale`, so macOS may remove its files.
  func release(_ locale: Locale) async
}

/// The language a system model starts with: the user's first preferred language it supports.
enum LocaleChoice {
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
