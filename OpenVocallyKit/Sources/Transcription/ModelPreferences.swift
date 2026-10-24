import Foundation
import Models

/// The stored active model and each system model's language. Anyone can read them; only the
/// model library writes them, so a harness run cannot change what the user picked.
public struct ModelPreferences: Sendable {
  nonisolated(unsafe) private let defaults: UserDefaults  // allowed: UserDefaults is documented thread-safe

  static let activeKey = "transcription.modelID"
  static func localeKey(_ model: SystemModel) -> String { "transcription.locale.\(model.id.rawValue)" }

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// Nil when nothing is stored, or the stored model is no longer in the catalog.
  public var active: ModelID? {
    defaults.string(forKey: Self.activeKey).flatMap(ModelID.init(rawValue:))
  }

  /// The language identifier the user chose or installed for `model`, if any.
  public func locale(for model: SystemModel) -> String? {
    defaults.string(forKey: Self.localeKey(model))
  }

  func setActive(_ model: ModelID) {
    defaults.set(model.rawValue, forKey: Self.activeKey)
  }

  func setLocale(_ locale: Locale, for model: SystemModel) {
    defaults.set(locale.identifier, forKey: Self.localeKey(model))
  }
}
