import DesignSystem
import SwiftUI

/// The step's symbol in an ink tile, its title and one line.
struct StepHeader: View {
  let symbol: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: Space.l.points) {
      Image(systemName: symbol)
        .textStyle(.title1)
        .fontWeight(.semibold)
        .foregroundStyle(.token(.onAccent))
        .contentTransition(.symbolEffect(.replace))
        .frame(width: Self.tile, height: Self.tile)
        .background(.token(.accent), in: Radius.card.shape)
        .accessibilityHidden(true)
      VStack(spacing: Space.xs.points) {
        Text(title)
          .textStyle(.title2)
          .fontWeight(.semibold)
          .id(title)
          .transition(.blurReplace)
        Text(message)
          .textStyle(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .id(message)
          .transition(.blurReplace)
      }
      .frame(maxWidth: Self.textWidth)
      .motion(.onboardingStep, value: title)
    }
  }

  static let tile: CGFloat = 56
  static let textWidth: CGFloat = 400
}
