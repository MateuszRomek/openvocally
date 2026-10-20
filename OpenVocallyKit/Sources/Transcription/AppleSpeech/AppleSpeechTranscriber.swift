import AVFoundation
import Foundation
import Models
import Speech
import Synchronization

/// One of Apple's speech models in one language, through SpeechAnalyzer. It streams: each
/// dictation gets its own analyzer, fed while the user records.
@available(macOS 26, *)
struct AppleSpeechTranscriber: Transcriber {
  let model: SystemModel
  let locale: Locale
  let format: AnalyzerFormat

  /// `.modelNotInstalled` when the language's assets are not installed. Prepares one analyzer,
  /// so the model is in memory before the first press; the analyzers keep it there for the
  /// life of the process.
  @concurrent
  static func load(_ model: SystemModel, locale: Locale) async throws(TranscriptionError) -> Self {
    let session = SpeechModuleSession(model, locale: locale)
    guard await AssetInventory.status(forModules: [session.module]) == .installed else {
      throw .modelNotInstalled
    }
    guard
      let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [session.module]),
      let format = AnalyzerFormat(best)
    else {
      transcriptionLogger.error("SpeechAnalyzer asks for an audio format OpenVocally doesn't produce")
      throw .engineFailed
    }
    let transcriber = Self(model: model, locale: locale, format: format)
    let start = ContinuousClock.now
    guard let warm = try await transcriber.openStream() else { throw .engineFailed }
    await warm.cancel()
    transcriptionLogger.notice(
      "Apple \(model.rawValue, privacy: .public) loaded in \((ContinuousClock.now - start).milliseconds, privacy: .public) ms"
    )
    return transcriber
  }

  @concurrent
  func openStream() async throws(TranscriptionError) -> (any TranscriptionStream)? {
    let session = SpeechModuleSession(model, locale: locale)
    // Lingering keeps the model warm between dictations as well as processLifetime does,
    // measured even after a minute idle, and still lets macOS free it under memory pressure.
    let analyzer = SpeechAnalyzer(
      modules: [session.module], options: .init(priority: .userInitiated, modelRetention: .lingering))
    let start = ContinuousClock.now
    let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    do {
      try await analyzer.prepareToAnalyze(in: format.audio)
      try await analyzer.start(inputSequence: input)
    } catch {
      continuation.finish()
      await analyzer.cancelAndFinishNow()
      transcriptionLogger.error(
        "SpeechAnalyzer didn't start: \(String(describing: error), privacy: .public)")
      throw .engineFailed
    }
    transcriptionLogger.info(
      "SpeechAnalyzer ready in \((ContinuousClock.now - start).milliseconds, privacy: .public) ms")
    return AnalyzerStream(
      analyzer: analyzer, input: continuation, format: format, text: Task { try await session.finalText() })
  }

  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    guard let stream = try await openStream() else { throw .engineFailed }
    return try await stream.finish(samples[...])
  }
}

/// The analyzer's input format, when it is one the 16 kHz mono recording packs into directly.
@available(macOS 26, *)
struct AnalyzerFormat: Sendable {
  let audio: AVAudioFormat

  init?(_ audio: AVAudioFormat) {
    guard audio.sampleRate == 16_000, audio.channelCount == 1,
      audio.commonFormat == .pcmFormatInt16 || audio.commonFormat == .pcmFormatFloat32
    else { return nil }
    self.audio = audio
  }

  func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audio, frameCapacity: AVAudioFrameCount(samples.count))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let int16 = buffer.int16ChannelData?[0] {
      for (index, sample) in samples.enumerated() {
        int16[index] = sample.isFinite ? Int16(max(-1, min(1, sample)) * Float(Int16.max)) : 0
      }
    } else if let float = buffer.floatChannelData?[0] {
      for (index, sample) in samples.enumerated() { float[index] = sample.isFinite ? sample : 0 }
    }
    return buffer
  }
}

/// One dictation's analyzer. Appends go straight into its input sequence; the text arrives as
/// final results, which `finish` waits for. A recording it couldn't take whole fails `finish`,
/// so the runtime transcribes the whole recording instead.
@available(macOS 26, *)
final class AnalyzerStream: TranscriptionStream {
  private let analyzer: SpeechAnalyzer
  private let input: AsyncStream<AnalyzerInput>.Continuation
  private let format: AnalyzerFormat
  private let text: Task<String, any Error>
  private let state = Mutex<(ended: Bool, dropped: Bool)>((false, false))

  init(
    analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AnalyzerFormat,
    text: Task<String, any Error>
  ) {
    self.analyzer = analyzer
    self.input = input
    self.format = format
    self.text = text
  }

  func append(_ samples: ArraySlice<Float>) {
    guard !samples.isEmpty else { return }
    guard let buffer = format.buffer(samples) else {
      state.withLock { $0.dropped = true }
      return
    }
    input.yield(AnalyzerInput(buffer: buffer))
  }

  func finish(_ rest: ArraySlice<Float>) async throws(TranscriptionError) -> String {
    guard end() else { throw .cancelled }
    append(rest)
    input.finish()
    guard !state.withLock({ $0.dropped }) else {
      await analyzer.cancelAndFinishNow()
      text.cancel()
      transcriptionLogger.error("SpeechAnalyzer missed audio it couldn't be given")
      throw .engineFailed
    }
    let start = ContinuousClock.now
    let joined: String
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      joined = try await text.value
    } catch {
      await analyzer.cancelAndFinishNow()
      text.cancel()
      transcriptionLogger.error("SpeechAnalyzer failed: \(String(describing: error), privacy: .public)")
      throw Task.isCancelled ? .cancelled : .engineFailed
    }
    transcriptionLogger.info(
      "SpeechAnalyzer finished in \((ContinuousClock.now - start).milliseconds, privacy: .public) ms")
    let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .noSpeech }
    return trimmed
  }

  func cancel() async {
    guard end() else { return }
    input.finish()
    await analyzer.cancelAndFinishNow()
    text.cancel()
  }

  /// True for the first caller only, so the analyzer ends once.
  private func end() -> Bool {
    state.withLock { state in
      defer { state.ended = true }
      return !state.ended
    }
  }
}

extension Duration {
  fileprivate var milliseconds: Int {
    Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }
}
