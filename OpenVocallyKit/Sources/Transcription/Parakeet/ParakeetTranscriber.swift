import CoreML
import FluidAudio
import Foundation
import Models
import os

/// A Parakeet TDT 0.6B model running in this process through FluidAudio.
public struct ParakeetTranscriber: Sendable {
  static let sampleRate = 16_000
  static let installedFiles = ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile])

  private let manager: AsrManager
  private let models: AsrModels

  /// FluidAudio's version and repository for `model`. Only Parakeet models have them.
  private static func fluidAudioModel(_ model: ModelID) -> (version: AsrModelVersion, repo: Repo)? {
    switch model {
    case .parakeetV3: (.v3, .parakeetV3)
    case .parakeetUltra: (.ultra, .parakeetUltra)
    case .whisperTurbo: nil
    }
  }

  /// The folder inside the model's install folder that FluidAudio loads from.
  static func repositoryFolder(of model: ModelID) -> String? {
    fluidAudioModel(model)?.repo.folderName
  }

  /// Loads `model` from `modelDirectory`, the folder that contains its repository folder.
  /// Call it at launch, not on the first press. Any load can take about 30 s while CoreML
  /// compiles the model, so callers must show a loading state.
  @concurrent
  public static func load(_ model: ModelID, modelDirectory: URL) async throws(TranscriptionError)
    -> ParakeetTranscriber
  {
    guard let (version, repo) = fluidAudioModel(model) else {
      preconditionFailure("\(model.name) is not a Parakeet model")
    }
    let repository = modelDirectory.appending(path: repo.folderName, directoryHint: .isDirectory)
    // loadLocal opens the components before it checks that the last one exists, so a missing
    // file behind a corrupt one would surface as a load failure instead of a missing model.
    let installed = installedFiles.allSatisfy {
      FileManager.default.fileExists(atPath: repository.appending(path: $0).path)
    }
    guard installed else { throw .modelNotInstalled }
    do {
      let models = try AsrModels.loadLocal(from: repository, version: version)
      try Task.checkCancellation()
      // Recordings over 15 s are split into windows. Three at a time gave the same text as one
      // at a time and cut a 30 s recording from 479 to 283 ms.
      let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 3), models: models)
      return ParakeetTranscriber(manager: manager, models: models)
    } catch AsrModelsError.modelNotFound {
      throw .modelNotInstalled
    } catch {
      throw failure(error, operation: "model load")
    }
  }

  /// Transcribes 16 kHz mono float samples. Callers run one transcription at a time.
  @concurrent
  public func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: Self.sampleRate) else {
      throw .noSpeech
    }
    let text: String
    do {
      var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
      text = try await manager.transcribe(samples, decoderState: &decoderState).text
    } catch {
      throw Self.failure(error, operation: "transcription")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .noSpeech }
    return trimmed
  }

  /// Runs the preprocessor and the encoder on one second of silence and drops the output. The
  /// Neural Engine clocks down during a quiet recording, which made the first encode after release
  /// two to four times slower.
  @concurrent
  public func keepWarm() async {
    guard let encoder = models.encoder else { return }
    do {
      let options = AsrModels.optimizedPredictionOptions()
      let features = try await models.preprocessor.compatPrediction(from: Self.silence(), options: options)
      _ = try await encoder.compatPrediction(from: features, options: options)
    } catch {
      transcriptionLogger.debug("Parakeet keep-warm failed: \(error.localizedDescription, privacy: .private)")
    }
  }

  /// One second of silence, padded to the fixed 15 s input every Parakeet call uses.
  private static func silence() throws -> MLDictionaryFeatureProvider {
    let audio = try MLMultiArray(
      shape: [1, NSNumber(value: ASRConstants.maxModelSamples)], dataType: .float32)
    audio.dataPointer.bindMemory(to: Float.self, capacity: ASRConstants.maxModelSamples)
      .initialize(repeating: 0, count: ASRConstants.maxModelSamples)
    let length = try MLMultiArray(shape: [1], dataType: .int32)
    length[0] = NSNumber(value: sampleRate)
    return try MLDictionaryFeatureProvider(dictionary: [
      "audio_signal": MLFeatureValue(multiArray: audio), "audio_length": MLFeatureValue(multiArray: length),
    ])
  }

  private static func failure(_ error: any Error, operation: String) -> TranscriptionError {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    transcriptionLogger.error(
      "Parakeet \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
    return .engineFailed
  }
}

extension ParakeetTranscriber: Transcriber {
  public static let lookahead = Lookahead.wholeRecording(window: ASRConstants.maxModelSamples)

  public var lookahead: Lookahead { Self.lookahead }
}
