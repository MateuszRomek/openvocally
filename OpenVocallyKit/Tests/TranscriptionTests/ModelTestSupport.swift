import Synchronization

@testable import Models
@testable import Transcription

struct FakeTranscriber: Transcriber {
  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String { "text" }
}

/// Counts loads and fails them on request.
final class LoadLog: Sendable {
  private let state = Mutex<(loads: [ModelID], failing: Bool)>(([], false))

  var loads: [ModelID] { state.withLock { $0.loads } }

  func fail(_ failing: Bool) { state.withLock { $0.failing = failing } }

  func load(_ loaded: RuntimeModel) throws(TranscriptionError) -> any Transcriber {
    let failing = state.withLock { state in
      state.loads.append(loaded.model)
      return state.failing
    }
    if failing { throw .engineFailed }
    return FakeTranscriber()
  }
}
