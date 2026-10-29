import AppKit
import DesignSystem
import DictationCore
import Storage
import SwiftUI
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts")

/// The selected transcript in the inspector: what is stored about it, the full text, Copy and
/// Delete. It reads the transcript by id off the main actor and keeps the previous one on screen
/// until the next arrives, so a selection change swaps the content without a blank frame.
struct TranscriptDetailPane: View {
  let id: TranscriptItem.ID?
  let database: AppDatabase
  let close: () -> Void
  let delete: (TranscriptItem.ID) -> Void

  private enum Load: Equatable {
    case empty
    case loaded(TranscriptDetail)
    case failed
  }

  @State private var load: Load = .empty
  @State private var copied = false
  @Environment(\.calendar) private var calendar

  var body: some View {
    Group {
      switch (id, load) {
      case (nil, _), (_, .empty):
        Color.clear
      case (_, .failed):
        ContentUnavailableView(
          "Could not load this transcript", systemImage: "exclamationmark.triangle",
          description: Text("It is safe on this Mac. Select it again."))
      case (_, .loaded(let detail)):
        transcript(detail)
      }
    }
    .task(id: id) { await read() }
    .onExitCommand(perform: close)
  }

  private func read() async {
    guard let id else {
      load = .empty
      return
    }
    do {
      let detail = try await database.transcript(id: id)
      load = detail.map(Load.loaded) ?? .empty
    } catch is CancellationError {
    } catch {
      logger.error("Reading a transcript failed: \(String(describing: error), privacy: .private)")
      load = .failed
    }
  }

  /// The header, then the text filling the pane, then one quiet line of what is stored about the
  /// dictation, pinned to the bottom so the text starts right under the header.
  private func transcript(_ detail: TranscriptDetail) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      header(detail)
        .padding(.horizontal, .l)
        .padding(.top, .m)
        .padding(.bottom, .s)
      ScrollView {
        Text(detail.text)
          .textStyle(.body)
          .lineSpacing(LineSpacing.reading.points)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, .l)
          .padding(.vertical, .s)
      }
      .id(detail.id)
      if let facts = Self.facts(detail) {
        Text(facts)
          .textStyle(.footnote)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, .l)
          .padding(.vertical, .s)
      }
    }
  }

  private func header(_ detail: TranscriptDetail) -> some View {
    HStack(alignment: .center, spacing: Space.s.points) {
      AppIcon(bundleID: detail.bundleID, size: .detail)
      VStack(alignment: .leading, spacing: Space.xxs.points) {
        Text(detail.appName ?? "Unknown app")
          .textStyle(.headline)
          .lineLimit(1)
        Text(TranscriptDate.full(detail.createdAt, calendar: calendar))
          .textStyle(.subheadline)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: Space.s.points)
      HStack(spacing: Space.xs.points) {
        CopyButton("Copy Transcript", copied: $copied) {
          TranscriptClipboard.write(detail.text)
          return true
        }
        IconButton("Delete Transcript", systemImage: "trash") { delete(detail.id) }
        IconButton("Close", systemImage: "xmark", action: close)
      }
    }
  }

  /// "0:05 · 40 words · 480 wpm · Push to talk", leaving out what is unknown or zero.
  static func facts(_ detail: TranscriptDetail) -> String? {
    var facts: [String] = []
    if detail.recordingDuration > .zero { facts.append(duration(detail.recordingDuration)) }
    if detail.words > 0 { facts.append(detail.words == 1 ? "1 word" : "\(detail.words.formatted()) words") }
    if let pace = detail.wordsPerMinute, pace >= 1 { facts.append("\(Int(pace.rounded())) wpm") }
    if let mode = detail.mode { facts.append(mode == .pushToTalk ? "Push to talk" : "Toggle") }
    return facts.isEmpty ? nil : facts.joined(separator: " · ")
  }

  /// Minutes and seconds, "0:05" or "12:40".
  static func duration(_ duration: Duration) -> String {
    let seconds = Int((duration / .seconds(1)).rounded(.up))
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
  }
}
