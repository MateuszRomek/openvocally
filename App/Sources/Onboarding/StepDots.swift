import DesignSystem
import SwiftUI

/// Where the user is: a dot per step, the current one stretched into a capsule.
struct StepDots: View {
  let steps: [OnboardingStep]
  let current: OnboardingStep

  var body: some View {
    HStack(spacing: Space.xs.points) {
      ForEach(steps, id: \.self) { step in
        Capsule()
          .fill(step == current ? .token(.accent) : .token(.separator))
          .frame(width: step == current ? Self.wide : Self.dot, height: Self.dot)
      }
    }
    .motion(.onboardingStep, value: current)
    .accessibilityElement()
    .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
  }

  static let dot: CGFloat = 6
  static let wide: CGFloat = 18
}
