/// A speech model that ships with macOS rather than from a download OpenVocally verifies.
public enum SystemModel: String, Sendable, Hashable {
  case dictation
  case speech

  public var id: ModelID {
    switch self {
    case .dictation: .appleDictation
    case .speech: .appleSpeech
    }
  }
}
