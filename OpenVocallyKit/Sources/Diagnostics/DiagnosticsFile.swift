import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A plain-text diagnostics file the user reviews before attaching it to an issue.
public struct DiagnosticsFile: Sendable, Transferable {
  public let filename: String
  public let summary: String
  let text: String

  public var data: Data { Data(text.utf8) }

  /// Never throws; every failure becomes a line in the file. Runs off the main actor.
  @concurrent public static func build(_ snapshot: DiagnosticsSnapshot, now: Date = .now) async
    -> DiagnosticsFile
  {
    let logs = LogArchive.read(now: now)
    let crash = DiagnosticsReport.latestCrash(bundleID: snapshot.bundleID, now: now)
    let text = DiagnosticsReport.scrub(
      DiagnosticsReport.text(snapshot, logs: logs, crash: crash, now: now),
      home: NSHomeDirectory(), userName: NSUserName(), fullName: NSFullUserName())
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return DiagnosticsFile(
      filename: "OpenVocally Diagnostics \(formatter.string(from: now)).txt",
      summary: logs.summary, text: text)
  }

  public static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .plainText) { $0.data }
      .suggestedFileName { $0.filename }
  }
}
