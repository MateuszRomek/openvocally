import Foundation
import Synchronization
import os
import whisper

/// Whisper running in this process through whisper.cpp. The context is not thread-safe, so the
/// actor serializes calls. `whisper_full` blocks for hundreds of milliseconds, so the actor runs
/// on its own queue instead of holding a cooperative-pool thread.
public actor WhisperTranscriber: Transcriber {
  private let queue: DispatchSerialQueue
  private let model: Model

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  public static let lookahead = Lookahead.pieces(shortest: 10 * 16_000, longest: 15 * 16_000)

  public nonisolated var lookahead: Lookahead { Self.lookahead }

  /// Owns the whisper.cpp context and frees it with the transcriber.
  private struct Model: ~Copyable {
    let context: OpaquePointer

    deinit {
      whisper_free(context)
    }
  }

  private init(context: OpaquePointer) {
    queue = DispatchSerialQueue(label: "com.openvocally.whisper", qos: .userInitiated)
    model = Model(context: context)
  }

  private var context: OpaquePointer { model.context }

  /// Loads the single `.bin` model file. Call it at launch, not on the first press.
  @concurrent
  public static func load(modelFile: URL) async throws(TranscriptionError) -> WhisperTranscriber {
    silenceEngineLogs()
    guard FileManager.default.fileExists(atPath: modelFile.path) else { throw .modelNotInstalled }
    var parameters = whisper_context_default_params()
    parameters.use_gpu = true
    parameters.flash_attn = true
    guard let context = whisper_init_from_file_with_params(modelFile.path, parameters) else {
      transcriptionLogger.error("Whisper model load failed")
      throw .engineFailed
    }
    guard !Task.isCancelled else {
      whisper_free(context)
      throw .cancelled
    }
    return WhisperTranscriber(context: context)
  }

  /// Transcribes 16 kHz mono float samples, with parameters picked by length and the repeat
  /// guard of `WhisperDecoding`; whisper.cpp steps through long audio itself. Callers run one
  /// transcription at a time.
  public func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    guard samples.count >= WhisperDecoding.minimumSamples else { throw .noSpeech }
    let abort = AbortFlag()
    let result: Result<String, TranscriptionError> = await withTaskCancellationHandler {
      do throws(TranscriptionError) {
        return .success(
          try WhisperDecoding.transcribe(sampleCount: samples.count) {
            decode(samples, $0, abort: abort)
          })
      } catch {
        return .failure(error)
      }
    } onCancel: {
      abort.raise()
    }
    return try result.get()
  }

  private func decode(
    _ samples: [Float], _ decoding: WhisperDecoding.Parameters, abort: AbortFlag
  ) -> WhisperDecoding.Attempt {
    var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    parameters.n_threads = 1
    parameters.translate = false
    parameters.detect_language = false
    parameters.no_context = true
    parameters.no_timestamps = decoding.lean
    parameters.single_segment = decoding.lean
    parameters.audio_ctx = decoding.audioContext
    parameters.token_timestamps = false
    parameters.thold_pt = 0.01
    parameters.max_len = 60
    parameters.suppress_nst = false
    parameters.temperature = 0
    parameters.temperature_inc = 0.2
    parameters.entropy_thold = 2.4
    parameters.logprob_thold = -1
    parameters.no_speech_thold = 0.6
    parameters.greedy.best_of = decoding.lean ? 1 : 2
    parameters.beam_search.beam_size = -1
    parameters.print_special = false
    parameters.print_progress = false
    parameters.print_realtime = false
    parameters.print_timestamps = false
    parameters.abort_callback = { data in
      guard let data else { return false }
      return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isRaised
    }
    let status = withExtendedLifetime(abort) {
      parameters.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
      return "auto".withCString { language in
        "".withCString { prompt in
          parameters.language = language
          parameters.initial_prompt = prompt
          return samples.withUnsafeBufferPointer {
            whisper_full(context, parameters, $0.baseAddress, Int32($0.count))
          }
        }
      }
    }
    if abort.isRaised { return .aborted }
    guard status == 0 else {
      transcriptionLogger.error("Whisper decode failed with status \(status, privacy: .public)")
      return .failed
    }
    var segments: [String] = []
    for segment in 0..<whisper_full_n_segments(context) {
      guard let text = whisper_full_get_segment_text(context, segment) else { continue }
      segments.append(String(cString: text))
    }
    return .segments(segments)
  }

  /// Keeps load and Metal failures visible while dropping info and debug lines, which can carry
  /// file paths and timings. Engine text stays private in case it ever echoes a transcript.
  private static func silenceEngineLogs() {
    let forward: ggml_log_callback = { level, text, _ in
      guard let text, level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN else { return }
      let message = String(cString: text)
      if level == GGML_LOG_LEVEL_ERROR {
        transcriptionLogger.error("whisper.cpp: \(message, privacy: .private)")
      } else {
        transcriptionLogger.warning("whisper.cpp: \(message, privacy: .private)")
      }
    }
    whisper_log_set(forward, nil)
    ggml_log_set(forward, nil)
  }
}

/// Set from a cancellation handler while `whisper_full` polls it on the decoding thread.
private final class AbortFlag: Sendable {
  private let raised = Atomic<Bool>(false)

  var isRaised: Bool { raised.load(ordering: .relaxed) }

  func raise() { raised.store(true, ordering: .relaxed) }
}

/// The decoding policy around `whisper_full`, kept free of the model so it is testable.
enum WhisperDecoding {
  enum Attempt: Equatable {
    case segments([String])
    case failed
    case aborted
  }

  struct Parameters: Equatable {
    /// Encoder frames, 0 for the model's full 1500 (30 s).
    var audioContext: Int32
    /// No timestamps, one segment, best of 1. Faster on short clips, loses words over 30 s.
    var lean: Bool

    /// Full context, timestamps, best of 2.
    static let shipping = Parameters(audioContext: 0, lean: false)

    /// A context that fits the clip, decoded lean: 50 frames per second plus a margin, never
    /// under 512. Over 30 s, or when the fit reaches the full context, shipping.
    static func fitted(sampleCount: Int) -> Parameters {
      guard sampleCount <= 30 * 16_000 else { return .shipping }
      let frames = sampleCount * 50 / 16_000 + 64
      // With flash attention, cross-attention reads the context padded to 256 rows unmasked.
      let fit = max(512, (frames + 255) / 256 * 256)
      guard fit < 1500 else { return .shipping }
      return Parameters(audioContext: Int32(fit), lean: true)
    }
  }

  /// whisper.cpp's own 100 ms floor at 16 kHz. Below it `whisper_full` skips the mel and decodes
  /// the previous recording's, so short audio must never reach it.
  static let minimumSamples = 1600

  /// Runs `attempt` with the fitted parameters. A failed call runs once more. Text that repeats a
  /// phrase runs once more with `shipping`, whose text wins: a clipped context loops on its
  /// padding. If that run fails or finds nothing, the repeating text stands. An abort is final.
  static func transcribe(
    sampleCount: Int, _ attempt: (Parameters) -> Attempt
  ) throws(TranscriptionError) -> String {
    guard sampleCount >= minimumSamples else { throw .noSpeech }
    var parameters = Parameters.fitted(sampleCount: sampleCount)
    var repeating: String?
    var failures = 0
    while failures < 2 {
      guard !Task.isCancelled else { throw .cancelled }
      switch attempt(parameters) {
      case .aborted: throw .cancelled
      case .failed: failures += 1
      case .segments(let segments):
        let text = segments.joined(separator: "\n").split(whereSeparator: \.isWhitespace).joined(
          separator: " ")
        guard !text.isEmpty else {
          if let repeating { return repeating }
          throw .noSpeech
        }
        guard parameters != .shipping, RepeatedPhrase.longestRun(in: text) >= 3 else { return text }
        repeating = text
        parameters = .shipping
      }
    }
    if let repeating { return repeating }
    throw .engineFailed
  }
}
