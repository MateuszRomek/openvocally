import DesignSystem
import OverlayCore
import SwiftUI

/// Draws one notch frame. Animation is scoped by structure: the shape animates on the frame's
/// cue keyed on the footprint, and the content animates on `Motion.content` keyed on the strip
/// lead, so a content change never moves the shape.
struct NotchFrameView: View {
  let drawing: NotchDrawing
  let placement: NotchPlacement
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.reduceMotionOverride) private var reduceMotionOverride

  var body: some View {
    let reduceMotion = reduceMotionOverride ?? systemReduceMotion
    let footprint = drawing.scene.footprint
    ZStack(alignment: .top) {
      if reduceMotion {
        NotchFrameShape(drawing: drawing, placement: placement, reduceMotion: true)
          .id(footprint)
          .transition(.opacity)
      } else {
        NotchFrameShape(drawing: drawing, placement: placement, reduceMotion: false)
      }
    }
    .animation(drawing.motion.motion.resolved(reduceMotion: reduceMotion), value: footprint)
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(drawing.activity?.accessibilityLabel ?? "")
    .accessibilityHidden(drawing.activity == nil)
  }
}

private struct NotchFrameShape: View {
  let drawing: NotchDrawing
  let placement: NotchPlacement
  let reduceMotion: Bool

  var body: some View {
    let footprint = drawing.scene.footprint
    let size = placement.shapeSize(footprint)
    let shape = NotchShape(radii: NotchPlacement.radii(footprint), minimumSize: .zero)
    let key = drawing.activity.map(OverlayKey.init)
    ZStack(alignment: .top) {
      if let activity = drawing.activity {
        NotchFrameContent(activity: activity, notch: placement.notch)
          .id(key)
          .transition(contentTransition)
      }
    }
    // Keyed on the lead, not `key`: the bars states share one key, and the mic tint and bars
    // mode change between them.
    .animation(Motion.content.resolved(reduceMotion: reduceMotion), value: drawing.scene.strip)
    .frame(width: size.width, height: size.height, alignment: .top)
    .clipShape(shape)
    .background(Color.clear.surface(.notch, in: shape))
  }

  /// Content that arrives with a key press is at full opacity in the first frame (LB-01).
  private var contentTransition: AnyTransition {
    if drawing.motion == .keyboard { return .identity }
    return reduceMotion ? .opacity : AnyTransition(.blurReplace)
  }
}

struct NotchFrameContent: View {
  let activity: OverlayActivity
  let notch: NotchGeometry

  var body: some View {
    switch activity.body {
    case .compact(let trailing):
      NotchRowLayout(notch: notch, minimumWing: OverlayMetrics.notchStripWing) {
        ZStack { if let mark = LeadingMark(activity) { LeadingMarkView(mark: mark) } }
        ZStack { TrailingSlot(trailing: trailing, status: activity.status, meter: .meter) }
      }
    case .alert(let alert):
      VStack(spacing: 0) {
        Color.clear.frame(width: notch.size.width, height: notch.size.height)
        HStack(spacing: Space.s.points) {
          if let glyph = activity.glyph { GlyphSlot(glyph: glyph) }
          AlertBlock(alert: alert)
        }
        .padding(.horizontal, OverlayMetrics.notchDropInset)
        .frame(height: OverlayMetrics.notchNoticeDrop)
      }
    case .card:
      EmptyView()
    }
  }
}
