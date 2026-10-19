import FluidAudio
import Foundation
import Models
import Transcription

/// What every Parakeet strategy shares, loaded once per model. Add fields (for example FluidAudio's
/// `AsrModels`) when a strategy needs engine internals, and load them in `load`.
struct ParakeetModel: WholeBufferTranscriber {
  let transcriber: ParakeetTranscriber

  static func load(_ model: ModelID, from location: URL) async throws -> ParakeetModel {
    // FluidAudio can log transcript text; the app sets the same level before its first load.
    AppLogger.minimumLevel = .warning
    return ParakeetModel(transcriber: try await ParakeetTranscriber.load(model, modelDirectory: location))
  }

  var engine: any Transcriber { transcriber }

  func transcribeAll(_ samples: [Float]) async throws -> String {
    try await transcriber.transcribe(samples)
  }
}
