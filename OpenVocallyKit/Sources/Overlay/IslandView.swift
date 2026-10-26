import DesignSystem
import SwiftUI

struct IslandView: View {
  let activity: OverlayActivity

  var body: some View {
    ActivityRow(activity: activity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(activity.accessibilityLabel)
  }
}

/// One persistent pill. Only the content inside it swaps, so a change of state reshapes the
/// pill the user is already looking at instead of replacing it.
struct ActivityRow: View {
  let activity: OverlayActivity

  var body: some View {
    HStack(spacing: Space.s.points) {
      if let glyph = activity.glyph {
        GlyphSlot(glyph: glyph).transition(.blurReplace)
      } else if case .compact(.status) = activity.body {
        LeadingMarkView(mark: .mic(listening: false))
      }
      content
    }
    .padding(.horizontal, OverlayMetrics.labelInset)
    .padding(.vertical, Space.s)
    .frame(minWidth: OverlayMetrics.islandMinWidth, minHeight: OverlayMetrics.islandHeight)
    // New content lays out at its final size while the shape is still growing toward it.
    .clipShape(IslandShape(cornerRadius: cornerRadius))
    .background(IslandBackground(cornerRadius: cornerRadius))
  }

  @ViewBuilder private var content: some View {
    switch activity.body {
    case .compact(let trailing):
      TrailingSlot(trailing: trailing, status: activity.status)
        .transition(.blurReplace)
    case .alert(let alert):
      AlertBlock(alert: alert)
        .id(alert.message)
        .transition(.blurReplace)
    case .card(let card):
      CardBlock(card: card)
        .transition(.blurReplace)
    }
  }

  private var cornerRadius: CGFloat {
    switch activity.level {
    case .hidden, .compact: OverlayMetrics.islandHeight / 2
    case .alert: OverlayMetrics.islandAlertRadius
    case .card: OverlayMetrics.islandCardRadius
    }
  }
}

private struct IslandBackground: View {
  let cornerRadius: CGFloat

  var body: some View {
    Color.clear.surface(.island, in: IslandShape(cornerRadius: cornerRadius))
  }
}

/// One continuous rounded rect whose radius animates, clamped so a one-line island is a
/// capsule and a taller one a rounded rect, without switching shapes.
private struct IslandShape: Shape {
  var cornerRadius: CGFloat

  var animatableData: CGFloat {
    get { cornerRadius }
    set { cornerRadius = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
    return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
  }
}

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
      case .agent:
        symbol("sparkles").foregroundStyle(.secondary)
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
  var meter = Motion.overlayMeter

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

struct CardBlock: View {
  let card: OverlayCard

  var body: some View {
    VStack(alignment: .leading, spacing: Space.xxs.points) {
      Text(card.title).textStyle(.overlayLabel).foregroundStyle(.primary)
        .lineLimit(OverlayMetrics.cardLineLimit)
      if let detail = card.detail {
        Text(detail).textStyle(.overlayLabel).foregroundStyle(.secondary)
          .lineLimit(OverlayMetrics.cardLineLimit)
      }
    }
    .frame(maxWidth: OverlayMetrics.cardMaxWidth, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}
