import AppKit
import DesignSystem
import DictationCore
import Storage
import SwiftUI

/// A fixed-height row: the app's icon, two lines of the text and a compact date, with no day
/// headings. A Copy button takes the date's place while the pointer is over the row,
/// the row is selected or the copy is confirming.
struct TranscriptRow: View {
  let item: TranscriptItem
  /// Selected or under the pointer.
  let isActive: Bool
  let copy: () async -> Bool
  @State private var copied = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.s.points) {
      AppIcon(bundleID: item.bundleID)
        .centeredOnFirstTextLine()
        .help(item.appName ?? "Unknown app")
      Text(item.displayPreview)
        .textStyle(.body)
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      DateOrCopySlot(date: item.createdAt, showsCopy: isActive || copied) {
        CopyButton("Copy Transcript", copied: $copied, copy: copy)
      }
    }
    .padding(.vertical, .s)
  }
}

/// The date, or the Copy button in the date's own space, so showing it never moves the row.
private struct DateOrCopySlot<Copy: View>: View {
  let date: Date
  let showsCopy: Bool
  @ViewBuilder let copyButton: () -> Copy
  @Environment(\.calendar) private var calendar

  var body: some View {
    Text(TranscriptDate.compact(date, calendar: calendar))
      .textStyle(.subheadline)
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .help(TranscriptDate.full(date, calendar: calendar))
      .opacity(showsCopy ? 0 : 1)
      .overlay(alignment: .trailing) {
        if showsCopy { copyButton() }
      }
  }
}

extension View {
  /// Lines an icon up with the middle of the first text line beside it in a baseline row.
  fileprivate func centeredOnFirstTextLine() -> some View {
    alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Space.xs.points }
  }
}
