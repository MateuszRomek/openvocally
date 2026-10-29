import DesignSystem
import SwiftUI

struct BarsView: View {
  let mode: BarsMode
  /// The token the live bars follow the meter on.
  let meter: Motion
  @Environment(BarsModel.self) private var bars
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.reduceMotionOverride) private var reduceMotionOverride

  var body: some View {
    if reduceMotionOverride ?? systemReduceMotion {
      BarsShape(heights: Bars.heights(mode, bands: [], time: 0, reduceMotion: true))
    } else if mode == .live {
      let heights = Bars.heights(.live, bands: bars.bands, time: 0, reduceMotion: false)
      BarsShape(heights: heights).animation(meter.animation, value: heights)
    } else {
      TimelineView(.animation) { context in
        BarsShape(
          heights: Bars.heights(
            mode, bands: [], time: context.date.timeIntervalSinceReferenceDate, reduceMotion: false))
      }
    }
  }
}

private struct BarsShape: View {
  let heights: [Double]

  var body: some View {
    HStack(alignment: .center, spacing: OverlayMetrics.barSpacing) {
      ForEach(heights.indices, id: \.self) { index in
        Capsule()
          .frame(width: OverlayMetrics.barWidth, height: Self.points(heights[index]))
      }
    }
    .frame(height: OverlayMetrics.barMaxHeight)
    .accessibilityHidden(true)
  }

  private static func points(_ height: Double) -> CGFloat {
    OverlayMetrics.barMinHeight + (OverlayMetrics.barMaxHeight - OverlayMetrics.barMinHeight) * height
  }
}

/// Bar heights in 0...1. Pure, so every mode is testable without a view.
enum Bars {
  static let pulsePeriod: TimeInterval = 1.2
  static let sweepPeriod: TimeInterval = 1.0

  static func heights(_ mode: BarsMode, bands: [Float], time: TimeInterval, reduceMotion: Bool)
    -> [Double]
  {
    let count = OverlayMetrics.barCount
    let arch = (0..<count).map { sin(Double.pi * (Double($0) + 0.5) / Double(count)) }
    if reduceMotion { return arch.map { 0.2 + 0.5 * $0 } }
    switch mode {
    case .live:
      let start = max(0, (bands.count - count) / 2)
      let centre = bands.dropFirst(start).prefix(count).map { Double(min(1, max(0, $0))) }
      return centre + Array(repeating: 0, count: count - centre.count)
    case .pulse:
      let breath = 0.5 - 0.5 * cos(2 * Double.pi * time / pulsePeriod)
      return arch.map { (0.15 + 0.15 * breath) * (0.5 + 0.5 * $0) }
    case .sweep:
      return (0..<count).map { index in
        let phase = Double(index) / Double(count) - time / sweepPeriod
        let wave = 0.5 + 0.5 * cos(2 * Double.pi * phase)
        return 0.1 + 0.6 * wave * wave
      }
    }
  }
}

/// Read only by `BarsView`, so a meter tick re-evaluates nothing else.
@MainActor @Observable final class BarsModel {
  var bands: [Float]

  init(bands: [Float] = []) {
    self.bands = bands
  }
}
