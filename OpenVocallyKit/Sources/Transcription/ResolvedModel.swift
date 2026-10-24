import Foundation
import Models

/// What the runtime loads. A system model's language is part of it, so choosing another language
/// is a different value and `activate` reloads.
public enum ResolvedModel: Hashable, Sendable {
  case hosted(HostedModel)
  case system(SystemModel, Locale)

  public var id: ModelID {
    switch self {
    case .hosted(let model): model.id
    case .system(let model, _): model.id
    }
  }
}
