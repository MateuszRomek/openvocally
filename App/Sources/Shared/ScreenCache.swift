import Reporting
import Storage

/// The last Home report and the newest Transcripts page each screen showed, so a screen opened
/// again draws its content in its first frame instead of an empty one, while its database
/// observation catches up a few milliseconds later. Deletes clear it, so a deleted
/// transcript never shows again, even for a frame.
@MainActor final class ScreenCache {
  private var database: ObjectIdentifier?
  private var reports: [ReportRange: HomeReport] = [:]
  private var newest: TranscriptPage?

  func report(_ range: ReportRange, in database: AppDatabase) -> HomeReport? {
    scope(database)
    return reports[range]
  }

  func store(_ report: HomeReport, for range: ReportRange, in database: AppDatabase) {
    scope(database)
    reports[range] = report
  }

  /// The newest `limit` transcripts, when a larger page was stored.
  func newestPage(limit: Int, in database: AppDatabase) -> TranscriptPage? {
    scope(database)
    guard let newest, newest.items.count >= limit || !newest.hasMore else { return nil }
    return TranscriptPage(
      items: Array(newest.items.prefix(limit)), hasMore: newest.hasMore || newest.items.count > limit)
  }

  func store(_ page: TranscriptPage, in database: AppDatabase) {
    scope(database)
    newest = page
  }

  func removeAll() {
    reports = [:]
    newest = nil
  }

  private func scope(_ database: AppDatabase) {
    let id = ObjectIdentifier(database)
    guard id != self.database else { return }
    removeAll()
    self.database = id
  }
}
