import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct SpeechResamplerTests {
  @Test(arguments: [48_000.0, 44_100.0])
  func `converts in one shot to an exact 16 kHz count and keeps a sine's level`(rate: Double) throws {
    let seconds = 1.3
    let input = (0..<Int(rate * seconds)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
    let output = try #require(SpeechResampler.convert(input[...], from: rate))
    let expected = Double(input.count) * 16_000 / rate
    #expect(abs(Double(output.count) - expected) <= 1, "got \(output.count) frames")
    let steady = output.dropFirst(800).dropLast(800)
    let rms = sqrt(steady.reduce(0) { $0 + Double($1 * $1) } / Double(steady.count))
    let expectedRMS = 0.5 / 2.0.squareRoot()
    #expect(abs(rms - expectedRMS) / expectedRMS < 0.05, "rms \(rms)")
  }
}
