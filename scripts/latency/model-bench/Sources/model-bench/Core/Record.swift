import Foundation
import Transcription

/// One timed run: one line of `results.jsonl`. The keys are the documented format; add keys, never
/// rename them.
struct RunRecord: Codable, Sendable {
  var model: String
  var strategy: String
  var fixture: String
  var pace: String
  var audioSeconds: Double
  var run: Int
  /// From the moment the last `append` returned to the moment `finish` returned.
  var releaseToTextMs: Double
  /// Total time spent inside `append` calls: work done during recording.
  var appendBusyMs: Double
  /// The latest an `append` started after its chunk became available (realtime pace only).
  var maxAppendLagMs: Double
  /// The last `append` returned more than one chunk (20 ms) after the audio ended.
  var fellBehind: Bool
  var thermal: String
  var text: String
  var wer: Double?
  var error: String?
  /// Digital silence appended before the release (`--release-gap-ms`).
  var releaseGapMs = 0
  /// `RepeatedPhrase.longestRun` of the text: the longest phrase said twice in a row, in words.
  var repeatedWords = 0
  /// The text repeats a phrase of 3 or more words that the reference does not.
  var repeats = false

  /// Records a transcript. An empty reference expects no text, so any text scores a WER of 1.
  mutating func score(_ text: String, reference: String) {
    self.text = text
    wer = wordErrorRate(reference: reference, hypothesis: text)
    repeatedWords = RepeatedPhrase.longestRun(in: text)
    repeats = repeatedWords >= 3 && repeatedWords > RepeatedPhrase.longestRun(in: reference)
  }

  enum CodingKeys: String, CodingKey {
    case model, strategy, fixture, pace, run, thermal, text, wer, error
    case audioSeconds = "audio_s"
    case releaseToTextMs = "release_to_text_ms"
    case appendBusyMs = "append_busy_ms"
    case maxAppendLagMs = "max_append_lag_ms"
    case fellBehind = "fell_behind"
    case releaseGapMs = "release_gap_ms"
    case repeatedWords = "repeated_words"
    case repeats
  }
}

func thermalState() -> String {
  switch ProcessInfo.processInfo.thermalState {
  case .nominal: "nominal"
  case .fair: "fair"
  case .serious: "serious"
  case .critical: "critical"
  @unknown default: "unknown"
  }
}

/// Appends one JSON object per line and syncs it, so a crash keeps the finished runs.
final class JSONLWriter {
  private let handle: FileHandle
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  init(file: URL) throws {
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
  }

  func write(_ record: RunRecord) throws {
    try handle.write(contentsOf: encoder.encode(record) + Data("\n".utf8))
  }
}
