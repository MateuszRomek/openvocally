import DesignSystem
import Testing

@testable import Overlay

struct BarsTests {
  @Test func `live takes the centre sixteen of twenty bands in order`() {
    let bands = (0..<20).map { Float($0) / 20 }
    let heights = Bars.heights(.live, bands: bands, time: 0, reduceMotion: false)
    #expect(heights == (2..<18).map { Double(Float($0) / 20) })
  }

  @Test func `live without bands draws the floor`() {
    let heights = Bars.heights(.live, bands: [], time: 0, reduceMotion: false)
    #expect(heights == Array(repeating: 0, count: OverlayMetrics.barCount))
  }

  @Test func `reduce motion draws one static shape for every mode and time`() {
    let shapes = [BarsMode.pulse, .live, .sweep].flatMap { mode in
      [0, 0.4, 7.3].map { time in
        Bars.heights(mode, bands: [1, 0.5, 0.2], time: time, reduceMotion: true)
      }
    }
    #expect(Set(shapes).count == 1)
  }

  @Test(arguments: [BarsMode.pulse, .sweep])
  func `pulse and sweep move with time and stay in range`(mode: BarsMode) {
    let early = Bars.heights(mode, bands: [], time: 0, reduceMotion: false)
    let later = Bars.heights(mode, bands: [], time: 0.3, reduceMotion: false)
    #expect(early != later)
    #expect(early.count == OverlayMetrics.barCount)
    #expect((early + later).allSatisfy { (0...1).contains($0) })
  }
}
