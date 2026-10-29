import DesignSystem
import SwiftUI

struct GlyphSlot: View {
  let glyph: OverlayGlyph

  var body: some View {
    GlyphView(glyph: glyph)
      .id(glyph)
      .transition(.blurReplace)
  }
}

private struct GlyphView: View {
  let glyph: OverlayGlyph

  var body: some View {
    Group {
      switch glyph {
      case .success:
        symbol("checkmark").fontWeight(.bold).foregroundStyle(.token(.success))
      case .attention:
        symbol("exclamationmark.triangle.fill").foregroundStyle(.token(.attention))
      }
    }
    .frame(width: OverlayMetrics.glyphSize, height: OverlayMetrics.glyphSize)
    .accessibilityHidden(true)
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name).textStyle(.overlayGlyph)
  }
}

struct TrailingSlot: View {
  let trailing: OverlayActivity.Trailing
  let status: StatusWord
  let meter: Motion

  var body: some View {
    let key = Key(trailing: trailing, status: status)
    content
      .id(key)
      .transition(.blurReplace)
  }

  @ViewBuilder private var content: some View {
    switch trailing {
    case .bars(let mode):
      BarsView(mode: mode, meter: meter)
        .foregroundStyle(mode == .live ? Color.primary : Color.secondary)
    case .status:
      Text(status.text)
        .textStyle(.overlayLabel)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize()
    }
  }

  /// A bars mode change is not an identity change: the bars stay and change how they move.
  private enum Key: Hashable {
    case bars
    case word(String)

    init(trailing: OverlayActivity.Trailing, status: StatusWord) {
      switch trailing {
      case .bars: self = .bars
      case .status: self = .word(status.text)
      }
    }
  }
}

/// One short line with its key caps, and the countdown as a line that shrinks below it.
struct AlertBlock: View {
  let alert: OverlayAlert

  var body: some View {
    VStack(alignment: .leading, spacing: Space.s.points) {
      HStack(spacing: Space.xs.points) {
        Text(alert.message)
          .textStyle(.overlayLabel)
          .foregroundStyle(.primary)
          .lineLimit(1)
        ForEach(alert.keys, id: \.self) { KeyCap($0) }
      }
      .fixedSize()
      if let countdown = alert.countdown {
        CountdownBar(until: countdown.ends, total: countdown.total)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}
