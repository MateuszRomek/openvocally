import Testing

@testable import DesignSystem

@Test func spacingClimbsInFourPointStepsAfterTheTitleGap() {
  let steps = Space.allCases.map(\.points)
  #expect(steps == steps.sorted())
  #expect(steps.dropFirst().allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
}

@Test func radiiGrowWithTheSurface() {
  let radii = Radius.allCases.map(\.points)
  #expect(radii == radii.sorted())
}

/// `keyboard` is not decoration, but a key's feedback is instant under Reduce Motion rather than
/// faded in, so the first frame after a press already shows it.
@Test func onlyDecorationAndKeyFeedbackStopUnderReduceMotion() {
  #expect(Motion.allCases.filter { $0.reduced == nil } == [.overlayMeter, .keyboard, .meter])
  #expect(Motion.overlayExpand.resolved(reduceMotion: true) == Motion.overlayExpand.reduced)
  #expect(Motion.overlayExpand.resolved(reduceMotion: false) == Motion.overlayExpand.animation)
}

@Test func controlScaleMapsToTheSystemSizes() {
  #expect(ControlScale.allCases.map(\.controlSize) == [.small, .regular, .large])
}

@Test func onlyProgressDrawsASpinnerInsteadOfAColoredSymbol() {
  #expect(Status.allCases.filter { $0.symbol == nil } == [.progress])
  #expect(Status.allCases.filter { $0.color == nil } == [.progress])
  #expect(Status.failed.color == .destructive)
}
