import Models
import Transcription

/// Every strategy, per engine. Experimental strategies live in `Experiments/`
/// and are listed here; the change that ships a winner deletes the rest.
let parakeetStrategies: [any Strategy<ParakeetModel>.Type] = [
  BatchStrategy<ParakeetModel>.self, ShippingStrategy<ParakeetModel>.self,
]
let whisperStrategies: [any Strategy<WhisperModel>.Type] = [
  BatchStrategy<WhisperModel>.self, ShippingStrategy<WhisperModel>.self,
]

/// Each benchmarkable model with its loader and strategies.
let benches: [ModelBench] = ModelID.allCases.compactMap { model in
  switch model.engine {
  case .parakeet:
    ModelBench(model, strategies: parakeetStrategies, load: { try await ParakeetModel.load(model, from: $0) })
  case .whisper: ModelBench(model, strategies: whisperStrategies, load: WhisperModel.load)
  case .apple: nil
  }
}
