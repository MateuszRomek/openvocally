import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct LevelMeterTests {
  private let rate = 48_000.0

  private func sine(hz: Double, amplitude: Float) -> [Float] {
    (0..<LevelMeter.fftSize).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
  }

  @Test func `silence reads as zero`() {
    var meter = LevelMeter()
    let silence = [Float](repeating: 0, count: LevelMeter.fftSize)
    var levels = AudioLevels.silent
    for _ in 0..<5 { levels = meter.analyze(samples: silence, sampleRate: rate, elapsed: .seconds(2)) }
    #expect(levels.level < 0.001)
    #expect(levels.bands.allSatisfy { $0 < 0.001 })
  }

  @Test func `a spoken-level tone reads well above silence`() {
    var meter = LevelMeter()
    let tone = sine(hz: 1000, amplitude: 0.1)
    var levels = AudioLevels.silent
    for _ in 0..<5 { levels = meter.analyze(samples: tone, sampleRate: rate, elapsed: .seconds(2)) }
    #expect(levels.level > 0.2)
  }

  @Test(arguments: [0.0, 0.01, 0.3, 1.0])
  func `there are always 20 bands in 0 to 1`(amplitude: Float) {
    var meter = LevelMeter()
    for elapsed in [Duration.zero, .seconds(2)] {
      let levels = meter.analyze(
        samples: sine(hz: 440, amplitude: amplitude), sampleRate: rate, elapsed: elapsed)
      #expect(levels.bands.count == 20)
      #expect(levels.bands.allSatisfy { (0...1).contains($0) })
      #expect((0...1).contains(levels.level))
    }
  }

  @Test func `a short buffer is padded, not rejected`() {
    var meter = LevelMeter()
    let levels = meter.analyze(samples: [Float](repeating: 0.2, count: 10), sampleRate: rate, elapsed: .zero)
    #expect(levels.bands.count == 20)
  }

  @Test func `the band holding 1 kHz is the loudest`() throws {
    var meter = LevelMeter()
    var bytes: [UInt8] = []
    for _ in 0..<5 { bytes = meter.frequencyBytes(sine(hz: 1000, amplitude: 0.05)) }
    let peaks = LevelMeter.bandPeaks(bytes, sampleRate: rate)
    let edges = LevelMeter.bandEdges(binCount: bytes.count, sampleRate: rate)
    let bin = Int(1000 / (rate / 2) * Double(bytes.count))
    let expected = try #require(
      (0..<20).first { edges[$0] <= bin && bin < max(edges[$0] + 1, edges[$0 + 1]) })
    let loudest = try #require(peaks.indices.max { peaks[$0] < peaks[$1] })
    #expect(loudest == expected)
  }

  @Test func `centre-out puts even bands on the left and odd bands on the right`() {
    let arranged = LevelMeter.arrangeCenterOut((0..<20).map(Float.init))
    let expected: [Float] = [18, 16, 14, 12, 10, 8, 6, 4, 2, 0, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
    #expect(arranged == expected)
  }
}
