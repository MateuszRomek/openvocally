import Foundation
import Models

/// What the runtime loads. A system model's language is part of it, so choosing another language
/// is a different value and `activate` reloads.
public enum RuntimeModel: Hashable, Sendable {
  case downloaded(ModelID)
  case system(SystemModel, Locale)

  public var model: ModelID {
    switch self {
    case .downloaded(let model): model
    case .system(.dictation, _): .appleDictation
    case .system(.speech, _): .appleSpeech
    }
  }
}
