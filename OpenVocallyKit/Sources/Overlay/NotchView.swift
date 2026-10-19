import DesignSystem
import SwiftUI

struct NotchStage: View {
  let scene: OverlayScene
  let notch: NotchGeometry
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .top) {
      if reduceMotion {
        if let primary = scene.primary {
          NotchBody(activity: primary, notch: notch)
            .id(OverlayKey(primary))
            .transition(.opacity)
        }
      } else {
        NotchBody(activity: scene.primary, notch: notch)
      }
    }
    .environment(\.colorScheme, .dark)
  }
}

struct NotchBody: View {
  let activity: OverlayActivity?
  let notch: NotchGeometry

  var body: some View {
    let shape = NotchShape(radii: radii, minimumSize: notch.hiddenSize)
    ZStack(alignment: .top) {
      if let activity {
        NotchContent(activity: activity, notch: notch)
          .transition(.asymmetric(insertion: .identity, removal: .opacity))
      }
    }
    .frame(minWidth: minSize.width, minHeight: minSize.height, alignment: .top)
    .clipShape(shape)
    .background(Color.clear.surface(.notch, in: shape))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(activity?.accessibilityLabel ?? "")
    .accessibilityHidden(activity == nil)
  }

  private var minSize: CGSize {
    guard activity != nil else { return notch.hiddenSize }
    return CGSize(width: notch.size.width + 2 * OverlayMetrics.notchWing, height: notch.size.height)
  }

  private var radii: NotchRadii {
    switch activity?.level ?? .hidden {
    case .hidden: OverlayMetrics.notchHiddenRadii
    case .compact: OverlayMetrics.notchCompactRadii
    case .alert: OverlayMetrics.notchAlertRadii
    case .card: OverlayMetrics.notchCardRadii
    }
  }
}

private struct NotchContent: View {
  let activity: OverlayActivity
  let notch: NotchGeometry

  var body: some View {
    switch activity.body {
    case .compact(let trailing):
      NotchRowLayout(notch: notch) {
        ZStack { if let mark = LeadingMark(activity) { LeadingMarkView(mark: mark) } }
        ZStack { TrailingSlot(trailing: trailing, status: activity.status) }
      }
      .transition(.blurReplace)
    case .alert(let alert):
      below {
        HStack(spacing: Space.s.points) {
          if let glyph = activity.glyph { GlyphSlot(glyph: glyph) }
          AlertBlock(alert: alert)
        }
        .id(alert.message)
      }
    case .card(let card):
      below {
        HStack(alignment: .top, spacing: Space.s.points) {
          if let glyph = activity.glyph { GlyphSlot(glyph: glyph) }
          CardBlock(card: card)
        }
      }
    }
  }

  private func below(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(spacing: 0) {
      Color.clear.frame(width: notch.size.width, height: notch.size.height)
      content()
        .padding(.horizontal, OverlayMetrics.notchDropInset)
        .padding(.bottom, OverlayMetrics.notchDropInset)
    }
    .transition(.blurReplace)
  }
}

enum LeadingMark: Hashable {
  case glyph(OverlayGlyph)
  case mic(listening: Bool)

  init?(_ activity: OverlayActivity) {
    if let glyph = activity.glyph {
      self = .glyph(glyph)
      return
    }
    switch activity.body {
    case .compact(.bars(let mode)): self = .mic(listening: mode == .live)
    case .compact(.status): self = .mic(listening: false)
    case .alert, .card: return nil
    }
  }
}

struct LeadingMarkView: View {
  let mark: LeadingMark

  var body: some View {
    switch mark {
    case .glyph(let glyph):
      GlyphSlot(glyph: glyph)
    case .mic(let listening):
      Image(systemName: "mic.fill")
        .textStyle(.overlayGlyph)
        .foregroundStyle(listening ? Color.primary : Color.secondary)
        .frame(width: OverlayMetrics.glyphSize, height: OverlayMetrics.glyphSize)
        .accessibilityHidden(true)
        .transition(.blurReplace)
    }
  }
}

/// Exactly two subviews, the leading and the trailing wing. Each is a `ZStack`, so a swap inside
/// a wing never adds a subview here. Each sits centered in its wing.
struct NotchRowLayout: Layout {
  let notch: NotchGeometry

  static func wingWidth(leading: CGFloat, trailing: CGFloat) -> CGFloat {
    max(OverlayMetrics.notchWing, max(leading, trailing) + 2 * OverlayMetrics.notchWingInset)
  }

  struct Measured {
    var sizes: [CGSize]
    var wing: CGFloat
  }

  func makeCache(subviews: Subviews) -> Measured {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let wing = Self.wingWidth(
      leading: sizes.first?.width ?? 0, trailing: sizes.dropFirst().first?.width ?? 0)
    return Measured(sizes: sizes, wing: wing)
  }

  func updateCache(_ cache: inout Measured, subviews: Subviews) {
    cache = makeCache(subviews: subviews)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) -> CGSize {
    CGSize(width: notch.size.width + 2 * cache.wing, height: notch.size.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured
  ) {
    for (index, subview) in subviews.enumerated() {
      let wingMinX = index == 0 ? bounds.minX : bounds.minX + cache.wing + notch.size.width
      subview.place(
        at: CGPoint(x: wingMinX + cache.wing / 2, y: bounds.midY), anchor: .center,
        proposal: ProposedViewSize(cache.sizes[index]))
    }
  }
}

struct NotchShape: Shape {
  var radii: NotchRadii
  let minimumSize: CGSize

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(radii.top, radii.bottom) }
    set { radii = NotchRadii(top: newValue.first, bottom: newValue.second) }
  }

  func drawnRect(in rect: CGRect) -> CGRect {
    let width = max(rect.width, minimumSize.width)
    let height = max(rect.height, minimumSize.height)
    return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
  }

  func path(in rect: CGRect) -> Path {
    let r = drawnRect(in: rect)
    let top = min(radii.top, r.height / 2)
    let bottom = max(0, min(radii.bottom, r.height - top, r.width / 2))
    var path = Path()
    path.move(to: CGPoint(x: r.minX - top, y: r.minY))
    path.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + top), control: CGPoint(x: r.minX, y: r.minY))
    path.addLine(to: CGPoint(x: r.minX, y: r.maxY - bottom))
    path.addQuadCurve(to: CGPoint(x: r.minX + bottom, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
    path.addLine(to: CGPoint(x: r.maxX - bottom, y: r.maxY))
    path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - bottom), control: CGPoint(x: r.maxX, y: r.maxY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY + top))
    path.addQuadCurve(to: CGPoint(x: r.maxX + top, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
    path.closeSubpath()
    return path
  }
}
