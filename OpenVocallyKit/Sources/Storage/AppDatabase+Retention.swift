import Foundation
import GRDB

/// How long transcripts are kept before they are deleted on their own.
public enum TranscriptRetention: String, CaseIterable, Identifiable, Sendable {
  case never
  case days7
  case days30
  case days90

  public static let defaultsKey = "transcriptRetention"

  public var id: Self { self }

  var days: Int? {
    switch self {
    case .never: nil
    case .days7: 7
    case .days30: 30
    case .days90: 90
    }
  }

  /// Sessions that started before this moment are deleted; nil keeps everything.
  public func cutoff(now: Date) -> Date? {
    days.map { now.addingTimeInterval(-Double($0) * 86_400) }
  }

  public static var saved: TranscriptRetention {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .never
  }
}

extension AppDatabase {
  /// Deletes every session that started before `cutoff`, with its transcript and metrics, in one
  /// transaction. Returns the number of sessions deleted.
  @discardableResult
  public func deleteTranscripts(olderThan cutoff: Date) async throws -> Int {
    let cutoffMs = unixMilliseconds(cutoff)
    return try await writer.write { db in
      try db.execute(sql: "DELETE FROM sessions WHERE started_at < ?", arguments: [cutoffMs])
      return db.changesCount
    }
  }

  @discardableResult
  public func deleteAllTranscripts() async throws -> Int {
    try await writer.write { db in
      try db.execute(sql: "DELETE FROM sessions")
      return db.changesCount
    }
  }

  /// Emits whether any transcript is saved, again after every change.
  public func hasTranscripts() -> some AsyncSequence<Bool, any Error> {
    ValueObservation.tracking {
      try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM transcripts)") ?? false
    }
    .removeDuplicates()
    .values(in: writer)
  }

  public func transcriptCount() async throws -> Int {
    try await writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcripts") ?? 0 }
  }
}
