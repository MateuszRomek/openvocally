import Foundation
import Models

/// The only way into the Speech framework from shared code, so macOS 15 never reaches it.
public enum AppleSpeech {
  /// No models before macOS 26, which has no SpeechAnalyzer.
  public static func store() -> any SystemModelStore {
    guard #available(macOS 26, *) else { return NoSystemModels() }
    return AppleSpeechAssets()
  }

  static func load(_ model: SystemModel, locale: Locale) async throws(TranscriptionError) -> any Transcriber {
    guard #available(macOS 26, *) else { throw .modelNotInstalled }
    return try await AppleSpeechTranscriber.load(model, locale: locale)
  }
}
