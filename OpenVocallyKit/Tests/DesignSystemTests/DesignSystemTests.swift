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

@Test func onlyDecorationStopsUnderReduceMotion() {
  #expect(Motion.allCases.filter { $0.reduced == nil } == [.overlayMeter])
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
