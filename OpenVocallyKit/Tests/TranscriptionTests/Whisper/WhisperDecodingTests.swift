import Testing

@testable import Transcription

struct WhisperDecodingTests {
  @Test func `a failed call runs once more and returns its text`() throws {
    var calls = 0
    let text = try WhisperDecoding.transcribe(sampleCount: 16_000) { _ in
      calls += 1
      return calls == 1 ? .failed : .segments([" Hello\n there. ", " Bye."])
    }
    #expect(calls == 2)
    #expect(text == "Hello there. Bye.")
  }

  @Test func `empty text is final`() {
    var calls = 0
    #expect(throws: TranscriptionError.noSpeech) {
      try WhisperDecoding.transcribe(sampleCount: 16_000) { _ in
        calls += 1
        return .segments([" ", ""])
      }
    }
    #expect(calls == 1)
  }

  @Test func `two failed calls fail the engine`() {
    var calls = 0
    #expect(throws: TranscriptionError.engineFailed) {
      try WhisperDecoding.transcribe(sampleCount: 16_000) { _ in
        calls += 1
        return .failed
      }
    }
    #expect(calls == 2)
  }

  @Test func `an aborted call is cancelled without a retry`() {
    var calls = 0
    #expect(throws: TranscriptionError.cancelled) {
      try WhisperDecoding.transcribe(sampleCount: 16_000) { _ in
        calls += 1
        return .aborted
      }
    }
    #expect(calls == 1)
  }

  @Test func `a cancelled task makes no call`() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var calls = 0
      let result = Result { () throws(TranscriptionError) in
        try WhisperDecoding.transcribe(sampleCount: 16_000) { _ in
          calls += 1
          return .segments(["Hello"])
        }
      }
      return (result, calls)
    }
    let (result, calls) = await task.value
    #expect(calls == 0)
    #expect(result == .failure(.cancelled))
  }

  @Test(arguments: [0, WhisperDecoding.minimumSamples - 1])
  func `audio under 100 ms is no speech and never decodes`(sampleCount: Int) {
    var calls = 0
    #expect(throws: TranscriptionError.noSpeech) {
      try WhisperDecoding.transcribe(sampleCount: sampleCount) { _ in
        calls += 1
        return .segments(["Stale text"])
      }
    }
    #expect(calls == 0)
  }

  @Test func `100 ms of audio decodes`() throws {
    let text = try WhisperDecoding.transcribe(sampleCount: WhisperDecoding.minimumSamples) { _ in
      .segments(["Hi"])
    }
    #expect(text == "Hi")
  }

  @Test(arguments: [(1.0, 512), (5, 512), (15, 1024), (20, 1280)])
  func `the context fits the clip and decodes lean`(seconds: Double, frames: Int32) {
    #expect(
      WhisperDecoding.Parameters.fitted(sampleCount: Int(seconds * 16_000))
        == WhisperDecoding.Parameters(audioContext: frames, lean: true))
  }

  @Test(arguments: [28.0, 30, 31])
  func `a clip that needs the full context decodes with the shipping parameters`(seconds: Double) {
    #expect(WhisperDecoding.Parameters.fitted(sampleCount: Int(seconds * 16_000)) == .shipping)
  }

  @Test func `a repeated phrase decodes again with the shipping parameters`() throws {
    var seen: [WhisperDecoding.Parameters] = []
    let text = try WhisperDecoding.transcribe(sampleCount: 16_000) { parameters in
      seen.append(parameters)
      return .segments([seen.count == 1 ? "Maybe around 2? Maybe around 2?" : "Maybe around 2?"])
    }
    #expect(seen == [.fitted(sampleCount: 16_000), .shipping])
    #expect(text == "Maybe around 2?")
  }

  @Test func `the shipping text is final even when it repeats`() throws {
    var seen: [WhisperDecoding.Parameters] = []
    let text = try WhisperDecoding.transcribe(sampleCount: 31 * 16_000) { parameters in
      seen.append(parameters)
      return .segments(["Maybe around 2? Maybe around 2?"])
    }
    #expect(seen == [.shipping])
    #expect(text == "Maybe around 2? Maybe around 2?")
  }

  @Test(arguments: [WhisperDecoding.Attempt.failed, .segments([])])
  func `the repeating text stands when the shipping retry finds nothing`(
    retry: WhisperDecoding.Attempt
  ) throws {
    var calls = 0
    let text = try WhisperDecoding.transcribe(sampleCount: 16_000) { _ in
      calls += 1
      return calls == 1 ? .segments(["send it to me send it to me"]) : retry
    }
    #expect(text == "send it to me send it to me")
  }
}
