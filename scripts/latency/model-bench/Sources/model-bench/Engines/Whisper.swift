import Foundation
import Transcription

/// What every Whisper strategy shares, loaded once per model. A strategy that needs the whisper.cpp
/// C API adds a binaryTarget on ../../../OpenVocallyKit/Vendor/whisper.xcframework to Package.swift.
struct WhisperModel: WholeBufferTranscriber {
  let transcriber: WhisperTranscriber

  static func load(_ location: URL) async throws -> WhisperModel {
    WhisperModel(transcriber: try await WhisperTranscriber.load(modelFile: location))
  }

  var engine: any Transcriber { transcriber }

  func transcribeAll(_ samples: [Float]) async throws -> String {
    try await transcriber.transcribe(samples)
  }
}
