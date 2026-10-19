import DictationCore
import Foundation

/// One row of the Transcripts list: the start of the text, not all of it.
public struct TranscriptItem: Identifiable, Sendable, Equatable {
  /// The transcript row id.
  public let id: Int64
  public let createdAt: Date
  /// The start of the text, up to `previewLength` characters, ending on a whole grapheme.
  let preview: String
  let isTruncated: Bool
  public let recordingDuration: Duration
  public let appName: String?
  public let bundleID: String?

  public var displayPreview: String { isTruncated ? preview + "…" : preview }

  /// More than two lines of the widest list column hold.
  static let previewLength = 300

  public init(
    id: Int64, createdAt: Date, preview: String, recordingDuration: Duration, appName: String?,
    bundleID: String?, isTruncated: Bool = false
  ) {
    self.id = id
    self.createdAt = createdAt
    self.preview = isTruncated ? String(preview.dropLast()) : preview
    self.isTruncated = isTruncated
    self.recordingDuration = recordingDuration
    self.appName = appName
    self.bundleID = bundleID
  }
}

public struct TranscriptPage: Sendable, Equatable {
  public let items: [TranscriptItem]
  /// Older transcripts exist past these.
  public let hasMore: Bool

  public init(items: [TranscriptItem], hasMore: Bool) {
    self.items = items
    self.hasMore = hasMore
  }
}

/// One transcript with its full text and what is stored about its dictation, for the
/// Transcripts detail.
public struct TranscriptDetail: Identifiable, Sendable, Equatable {
  public let id: Int64
  public let createdAt: Date
  public let text: String
  public let recordingDuration: Duration
  public let appName: String?
  public let bundleID: String?
  /// Nil for a value this version does not know.
  public let mode: RecordingMode?
  public let words: Int
  /// The time spent dictating, from the metrics; nil without a metrics row.
  let effectiveDuration: Duration?

  public init(
    id: Int64, createdAt: Date, text: String, recordingDuration: Duration, appName: String?,
    bundleID: String?, mode: RecordingMode?, words: Int, effectiveDuration: Duration?
  ) {
    self.id = id
    self.createdAt = createdAt
    self.text = text
    self.recordingDuration = recordingDuration
    self.appName = appName
    self.bundleID = bundleID
    self.mode = mode
    self.words = words
    self.effectiveDuration = effectiveDuration
  }

  /// Words per minute of dictating time, or nil when that time is not above zero.
  public var wordsPerMinute: Double? {
    guard let effectiveDuration, effectiveDuration > .zero else { return nil }
    return Double(words) / (effectiveDuration / .seconds(60))
  }
}

struct TranscriptDay: Identifiable, Sendable, Equatable {
  /// The start of the day.
  let id: Date
  private(set) var items: [TranscriptItem]

  /// Groups consecutive items by day, keeping their order.
  static func group(_ items: [TranscriptItem], calendar: Calendar) -> [TranscriptDay] {
    var days: [TranscriptDay] = []
    for item in items {
      let start = calendar.startOfDay(for: item.createdAt)
      if days.last?.id == start {
        days[days.count - 1].items.append(item)
      } else {
        days.append(TranscriptDay(id: start, items: [item]))
      }
    }
    return days
  }
}
