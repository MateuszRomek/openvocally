import Foundation
import Models
import Speech

/// A fresh transcriber module for one analyzer, with the task that joins its final results.
@available(macOS 26, *)
struct SpeechModuleSession {
  let module: any SpeechModule
  let finalText: @Sendable () async throws -> String

  /// The progressive presets report volatile results while the user talks, which lets the
  /// analyzer finalize most of the text before the release.
  init(_ model: SystemModel, locale: Locale) {
    switch model {
    case .dictation:
      let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
      module = transcriber
      finalText = Self.joined(transcriber.results) { $0.text }
    case .speech:
      let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
      module = transcriber
      finalText = Self.joined(transcriber.results) { $0.text }
    }
  }

  /// The text of the final results, in order. Volatile results are previews the final ones redo.
  private static func joined<Results: AsyncSequence<Results.Element, any Error> & Sendable>(
    _ results: Results, text: @escaping @Sendable (Results.Element) -> AttributedString
  ) -> @Sendable () async throws -> String where Results.Element: SpeechModuleResult {
    {
      var joined = ""
      for try await result in results where result.isFinal {
        joined += String(text(result).characters)
      }
      return joined
    }
  }

  static func supportedLocales(_ model: SystemModel) async -> [Locale] {
    switch model {
    case .dictation: await DictationTranscriber.supportedLocales
    case .speech: await SpeechTranscriber.supportedLocales
    }
  }
}
