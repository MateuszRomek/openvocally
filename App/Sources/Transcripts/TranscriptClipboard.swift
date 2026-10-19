import AppKit
import DesignSystem
import DictationCore
import Storage
import SwiftUI
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts")

enum TranscriptClipboard {
  /// Reads the full text by id, since the list holds only previews, and copies it. Returns whether
  /// it copied.
  static func copy(_ id: TranscriptItem.ID, from db: AppDatabase) async -> Bool {
    do {
      guard let detail = try await db.transcript(id: id) else { return false }
      write(detail.text)
      return true
    } catch {
      logger.error("Reading a transcript to copy failed: \(String(describing: error), privacy: .private)")
      return false
    }
  }

  /// Cmd-C's copy: SwiftUI makes the one pasteboard write, and the full text loads by id when
  /// the pasteboard asks for it.
  nonisolated static func provider(_ id: TranscriptItem.ID, from db: AppDatabase) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.register(TranscriptText(id: id, db: db))
    return provider
  }

  /// A plain, persistent write: the user asked for this text, so clipboard managers may keep it,
  /// unlike the transient write the paste path makes and restores.
  static func write(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
    AccessibilityNotification.Announcement("Transcript copied").post()
  }
}

/// A transcript's full text, read by id only when the pasteboard asks for it.
nonisolated private struct TranscriptText: Transferable {
  struct Missing: Error {}

  let id: TranscriptItem.ID
  let db: AppDatabase

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .utf8PlainText) { text in
      do {
        guard let detail = try await text.db.transcript(id: text.id) else { throw Missing() }
        return Data(detail.text.utf8)
      } catch {
        logger.error("Reading a transcript to copy failed: \(String(describing: error), privacy: .private)")
        throw error
      }
    }
  }
}
