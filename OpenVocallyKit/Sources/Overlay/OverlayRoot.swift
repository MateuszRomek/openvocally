import DesignSystem
import SwiftUI

/// The hosting root, created once per panel and never replaced.
struct OverlayRoot: View {
  let model: SceneModel
  let bars: BarsModel

  /// Drawn into every panel at alpha 0 by `prewarm`, so the first press finds the text,
  /// symbol and backing-store caches warm.
  static let warmFrame = OverlayActivity(
    glyph: nil, status: "Recording", body: .compact(.bars(.live)))

  var body: some View {
    OverlayStage(scene: model.scene, placement: model.placement)
      .frame(
        width: OverlayMetrics.canvas.width, height: OverlayMetrics.canvas.height,
        alignment: Alignment(horizontal: .center, vertical: model.placement.anchor.alignment)
      )
      .environment(bars)
  }
}

/// Renders activities without a panel, for the Design Gallery.
public struct OverlayPreview: View {
  private let scene: OverlayScene
  private let placement: OverlayPlacement
  @State private var bars: BarsModel

  public init(
    _ slots: [(OverlaySource, OverlayActivity)], placement: OverlayPlacement, bands: [Float] = []
  ) {
    scene = OverlayScene(Dictionary(slots, uniquingKeysWith: { _, last in last }))
    self.placement = placement
    _bars = State(initialValue: BarsModel(bands: bands))
  }

  public var body: some View {
    OverlayStage(scene: scene, placement: placement)
      .environment(bars)
  }
}

struct OverlayStage: View {
  let scene: OverlayScene
  let placement: OverlayPlacement

  var body: some View {
    switch placement {
    case .island(let edge): IslandStage(scene: scene, edge: edge)
    case .notch(let notch): NotchStage(scene: scene, notch: notch)
    }
  }
}

struct IslandStage: View {
  let scene: OverlayScene
  let edge: IslandEdge
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: Alignment(horizontal: .center, vertical: edge.anchor.alignment)) {
      if let primary = scene.primary {
        IslandView(activity: primary)
          .id(reduceMotion ? OverlayKey(primary) : nil)
          .transition(transition)
      }
    }
  }

  /// Appear scales from the edge with no opacity term, so the glyph and bars are at full
  /// opacity on the first frame (LB-01). Under Reduce Motion every change crossfades.
  private var transition: AnyTransition {
    if reduceMotion { return .opacity }
    let scale = AnyTransition(IslandAppear(anchor: edge.anchor.unitPoint))
    return .asymmetric(insertion: scale, removal: scale.combined(with: .opacity))
  }
}

struct OverlayKey: Hashable {
  let level: OverlayLevel
  let glyph: OverlayGlyph?
  let content: String

  init(_ activity: OverlayActivity) {
    level = activity.level
    glyph = activity.glyph
    content =
      switch activity.body {
      case .compact(.status): activity.status.text
      case .compact(.bars): "bars"
      case .alert(let alert): alert.message
      case .card(let card): card.title
      }
  }
}

struct IslandAppear: Transition {
  let anchor: UnitPoint

  func body(content: Content, phase: TransitionPhase) -> some View {
    content.scaleEffect(phase.isIdentity ? 1 : OverlayMetrics.appearScale, anchor: anchor)
  }
}

extension VerticalEdge {
  var alignment: VerticalAlignment {
    switch self {
    case .top: .top
    case .bottom: .bottom
    }
  }

  var unitPoint: UnitPoint {
    switch self {
    case .top: .top
    case .bottom: .bottom
    }
  }
}
