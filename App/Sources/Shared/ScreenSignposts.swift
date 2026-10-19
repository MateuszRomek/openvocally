import Foundation
import os

/// Signpost events in category "screens": durations and counts as public metadata, never
/// transcript text. Instruments shows them; the Debug harness also records them.
@MainActor enum ScreenSignposts {
  enum Mark {
    /// The Transcripts screen was created, to its first page shown.
    case transcriptsOpened(ms: Double, rows: Int)
    /// A load-more, to the grown page shown. `page` is 1 for the first load-more.
    case transcriptsGrew(page: Int, ms: Double, rows: Int)
    /// A transcript saved while the screen is open, to its row shown.
    case transcriptsNewRow(ms: Double, rows: Int)
    /// The Home screen was created, to its stats shown.
    case homeOpened(ms: Double)
    /// Home showed a report again, with this many sessions.
    case homeUpdated(sessions: Int)
    /// A screen was created, to its first query result arriving on the main actor.
    case firstValue(screen: String, ms: Double)
  }

  private static let signposter = OSSignposter(subsystem: "com.openvocally.app", category: "screens")

  #if DEBUG
    /// The in-process harness records and waits on these.
    static var observer: ((Mark) -> Void)?
  #endif

  static func transcriptsOpened(after duration: Duration, rows: Int) {
    let ms = milliseconds(duration)
    signposter.emitEvent(
      "TX-open", "ms=\(ms, format: .fixed(precision: 2), privacy: .public) rows=\(rows, privacy: .public)")
    notify(.transcriptsOpened(ms: ms, rows: rows))
  }

  static func transcriptsGrew(page: Int, after duration: Duration, rows: Int) {
    let ms = milliseconds(duration)
    signposter.emitEvent(
      "TX-more",
      "ms=\(ms, format: .fixed(precision: 2), privacy: .public) page=\(page, privacy: .public) rows=\(rows, privacy: .public)"
    )
    notify(.transcriptsGrew(page: page, ms: ms, rows: rows))
  }

  /// Wall clock from the save, so millisecond precision.
  static func transcriptsNewRow(savedAt: Date, rows: Int) {
    let ms = Date.now.timeIntervalSince(savedAt) * 1000
    signposter.emitEvent(
      "TX-save", "ms=\(ms, format: .fixed(precision: 2), privacy: .public) rows=\(rows, privacy: .public)")
    notify(.transcriptsNewRow(ms: ms, rows: rows))
  }

  static func homeOpened(after duration: Duration) {
    let ms = milliseconds(duration)
    signposter.emitEvent("HM-open", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    notify(.homeOpened(ms: ms))
  }

  static func homeUpdated(sessions: Int) {
    signposter.emitEvent("HM-update", "sessions=\(sessions, privacy: .public)")
    notify(.homeUpdated(sessions: sessions))
  }

  static func firstValue(screen: String, after duration: Duration) {
    let ms = milliseconds(duration)
    signposter.emitEvent(
      "first-value",
      "screen=\(screen, privacy: .public) ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    notify(.firstValue(screen: screen, ms: ms))
  }

  private static func notify(_ mark: Mark) {
    #if DEBUG
      observer?(mark)
    #endif
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
  }
}
