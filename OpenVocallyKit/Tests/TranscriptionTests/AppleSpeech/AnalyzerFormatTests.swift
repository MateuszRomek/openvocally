import AVFoundation
import Testing

@testable import Transcription

struct AnalyzerFormatTests {
  @available(macOS 26, *)
  @Test func `samples pack into 16-bit audio, clamped at full scale`() throws {
    let audio = try #require(
      AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let format = try #require(AnalyzerFormat(audio))
    let buffer = try #require(format.buffer([0, 0.5, -1, 2, -2][...]))
    let packed = try #require(buffer.int16ChannelData?[0])
    #expect((0..<5).map { packed[$0] } == [0, 16_383, -32_767, 32_767, -32_767])
  }

  @available(macOS 26, *)
  @Test func `samples that aren't numbers pack as silence`() throws {
    let samples: [Float] = [.nan, .infinity, -.infinity, 0.5]
    let int16 = try #require(
      AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let packing = try #require(AnalyzerFormat(int16))
    let packedBuffer = try #require(packing.buffer(samples[...]))
    let packed = try #require(packedBuffer.int16ChannelData?[0])
    #expect((0..<4).map { packed[$0] } == [0, 0, 0, 16_383])

    let float = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let copying = try #require(AnalyzerFormat(float))
    let copiedBuffer = try #require(copying.buffer(samples[...]))
    let copied = try #require(copiedBuffer.floatChannelData?[0])
    #expect((0..<4).map { copied[$0] } == [0, 0, 0, 0.5])
  }

  @available(macOS 26, *)
  @Test func `a format that needs resampling is refused`() throws {
    let audio = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    #expect(AnalyzerFormat(audio) == nil)
  }
}
