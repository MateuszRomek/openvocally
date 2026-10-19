import AppKit
import DesignSystem
import Overlay
import SwiftUI

/// Notch or island, each a small Mac screen telling the whole story: the overlay grows while you
/// talk, settles while it transcribes, then your words land in a window. Only the selected card
/// plays; a click restarts its loop and shows the real overlay for a moment.
/// Under Reduce Motion nothing loops: both cards hold the listening frame.
struct OverlayChoice: View {
  /// Shows the real overlay for a moment in the style just picked.
  let preview: () -> Void
  @AppStorage(OverlayStyle.defaultsKey) private var style = OverlayStyle.fallback
  @State private var phase = PreviewPhase.idle
  /// Bumped on every click, so clicking the selected card replays it from the start.
  @State private var clicks = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: Space.l.points) {
      ForEach(OverlayStyle.allCases, id: \.self) { option in
        card(option)
      }
    }
    .frame(maxWidth: Self.width)
    // The view leaves with the step, which cancels the loop; nothing runs off this step.
    .task(id: LoopKey(playing: style, clicks: clicks, reduceMotion: reduceMotion)) { await loop() }
  }

  private struct LoopKey: Equatable {
    let playing: OverlayStyle
    let clicks: Int
    let reduceMotion: Bool
  }

  private func loop() async {
    phase = .idle
    guard !reduceMotion else { return }
    while !Task.isCancelled {
      try? await Task.sleep(for: phase.holds)
      guard !Task.isCancelled else { return }
      let next = phase.next
      withAnimation(next.motion.animation) { phase = next }
    }
  }

  private func shownPhase(_ option: OverlayStyle) -> PreviewPhase {
    if reduceMotion { return .listening }
    return option == style ? phase : .idle
  }

  private func card(_ option: OverlayStyle) -> some View {
    let selected = option == style
    return Button {
      style = option
      clicks += 1
      preview()
    } label: {
      VStack(alignment: .leading, spacing: Space.s.points) {
        MiniScreen(style: option, phase: shownPhase(option))
          .frame(height: Self.sceneHeight)
        HStack {
          VStack(alignment: .leading, spacing: Space.xxs.points) {
            Text(option.title).textStyle(.headline).foregroundStyle(.primary)
            Text(option.detail).textStyle(.subheadline).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .textStyle(.title3)
            .foregroundStyle(selected ? .token(.accent) : .token(.separator))
            .contentTransition(.symbolEffect(.replace))
        }
      }
      .padding(Space.m)
      .surface(.card, in: Radius.card.shape)
      .overlay {
        Radius.card.shape
          .strokeBorder(
            selected ? .token(.accent) : .token(.separator), lineWidth: selected ? Self.ring : Self.hairline)
      }
      .contentShape(Radius.card.shape)
    }
    .appButton(.card)
    .motion(.windowReveal, value: selected)
    .accessibilityLabel(option.title)
    .accessibilityValue(option.detail)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  static let width: CGFloat = 460
  static let sceneHeight: CGFloat = 116
  static let ring: CGFloat = 2
  static let hairline: CGFloat = 1

  static var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }
}

/// One loop of the preview, about 3.5 s.
enum PreviewPhase: CaseIterable {
  case idle
  case listening
  case transcribing
  case pasted

  var next: PreviewPhase {
    switch self {
    case .idle: .listening
    case .listening: .transcribing
    case .transcribing: .pasted
    case .pasted: .idle
    }
  }

  var holds: Duration {
    switch self {
    case .idle: .milliseconds(700)
    case .listening: .milliseconds(1400)
    case .transcribing: .milliseconds(500)
    case .pasted: .milliseconds(1000)
    }
  }

  /// How the scene moves into this phase.
  var motion: Motion {
    switch self {
    case .idle: .onboardingExit
    case .listening: .overlayExpand
    case .transcribing: .overlayContentSwap
    case .pasted: .overlayCollapse
    }
  }

  var showsOverlay: Bool { self == .listening || self == .transcribing }
}

extension OverlayStyle {
  fileprivate var title: String {
    switch self {
    case .notch: "Notch"
    case .island: "Island"
    }
  }

  fileprivate var detail: String {
    switch self {
    case .notch: "Grows out of the notch"
    case .island: "Floats above the Dock"
    }
  }
}

/// A Mac in miniature: desktop, menu bar, one app window with a text field, and the overlay
/// where it would appear.
private struct MiniScreen: View {
  let style: OverlayStyle
  let phase: PreviewPhase

  var body: some View {
    ZStack {
      Rectangle().fill(.token(.selection))
      VStack(spacing: 0) {
        Rectangle().fill(.token(.windowBackground)).frame(height: Self.menuBar)
        Spacer(minLength: 0)
      }
      MiniWindow(pasted: phase == .pasted)
      switch style {
      case .notch:
        notch.frame(maxHeight: .infinity, alignment: .top)
      case .island:
        island.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, Space.s)
      }
    }
    .clipShape(Radius.small.shape)
    .overlay(Radius.small.shape.strokeBorder(.token(.separator)))
    .accessibilityHidden(true)
  }

  private var notch: some View {
    let open = phase.showsOverlay
    let size = open ? Self.notchOpen : Self.notchIdle
    return Color.clear
      .frame(width: size.width, height: size.height)
      .overlay { MiniMeter(phase: phase).opacity(open ? 1 : 0) }
      .surface(
        .notch,
        in: UnevenRoundedRectangle(
          bottomLeadingRadius: Radius.small.points, bottomTrailingRadius: Radius.small.points))
  }

  private var island: some View {
    let open = phase.showsOverlay
    return Color.clear
      .frame(width: Self.islandOpen.width, height: Self.islandOpen.height)
      .overlay { MiniMeter(phase: phase) }
      .surface(.island, in: Capsule())
      .scaleEffect(open ? 1 : OverlayMetrics.appearScale)
      .opacity(open ? 1 : 0)
  }

  static let menuBar: CGFloat = 8
  static let notchIdle = CGSize(width: 30, height: 8)
  static let notchOpen = CGSize(width: 92, height: 16)
  static let islandOpen = CGSize(width: 84, height: 18)
}

/// A small app window: a title bar strip and a text field where the words land.
private struct MiniWindow: View {
  let pasted: Bool

  var body: some View {
    VStack(spacing: 0) {
      Rectangle().fill(.token(.separator)).frame(height: Self.titleBar)
      VStack(alignment: .leading, spacing: Space.xxs.points) {
        line(width: Self.lineWidth, delay: 0)
        line(width: Self.lineWidth * Self.secondLine, delay: Self.secondDelay)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(Space.xs)
      .background(.token(.contentBackground), in: Radius.small.shape)
      .padding(Space.xs)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(.token(.windowBackground))
    .clipShape(Radius.small.shape)
    .overlay(Radius.small.shape.strokeBorder(.token(.separator)))
    .offset(y: Self.drop)
  }

  /// A placeholder line of text that grows from its leading edge, like words landing, and
  /// fades out before the next loop.
  private func line(width: CGFloat, delay: Double) -> some View {
    Capsule()
      .fill(.tertiary)
      .frame(width: pasted ? width : Self.lineHeight, height: Self.lineHeight)
      .opacity(pasted ? 1 : 0)
      .animation(
        pasted ? Motion.windowUnfold.animation.delay(delay) : Motion.onboardingExit.animation, value: pasted)
  }

  static let size = CGSize(width: 120, height: 54)
  static let titleBar: CGFloat = 8
  static let lineWidth: CGFloat = 84
  static let lineHeight: CGFloat = 4
  static let secondLine: CGFloat = 0.6
  static let secondDelay = 0.12
  static let drop: CGFloat = 2
}

/// A few bars like the overlay's meter: moving while listening, low and still while
/// transcribing. The timeline runs only while the bars move and Reduce Motion is off.
private struct MiniMeter: View {
  let phase: PreviewPhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let live = phase == .listening && !reduceMotion
    TimelineView(.animation(minimumInterval: Self.frame, paused: !live)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: Space.xxs.points) {
        ForEach(0..<Self.count, id: \.self) { index in
          Capsule()
            .frame(width: OverlayMetrics.barWidth, height: height(index, time: time, live: live))
        }
      }
    }
  }

  private func height(_ index: Int, time: Double, live: Bool) -> CGFloat {
    let wave: Double =
      switch phase {
      case .listening: live ? abs(sin(time * 5 + Double(index) * 0.9)) : Self.still[index % Self.still.count]
      default: Self.settled
      }
    return OverlayMetrics.barMinHeight + (Self.maxHeight - OverlayMetrics.barMinHeight) * wave
  }

  static let count = 7
  static let maxHeight: CGFloat = 9
  static let frame: Double = 1.0 / 30
  static let still: [Double] = [0.3, 0.6, 0.9, 0.7, 1, 0.5, 0.35]
  static let settled = 0.15
}
