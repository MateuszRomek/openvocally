import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

struct FrameSinkTests {
  private let rate = 24_000.0

  private func deliver(_ sink: FrameSink, count: Int, at start: HostTime, rate: Double) {
    var samples = [Float](repeating: 0.25, count: count)
    samples.withUnsafeMutableBufferPointer { buffer in
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
          mData: UnsafeMutableRawPointer(buffer.baseAddress)))
      withUnsafePointer(to: &list) { sink.receive(list: $0, frames: count, at: start, rate: rate) }
    }
  }

  @Test func `a stack buffer list at the recording rate yields a 16 kHz recording`() throws {
    let sink = FrameSink()
    sink.begin(RawFrames(press: press, sampleRate: rate, reservingSeconds: 1))
    for index in 0..<50 {
      deliver(sink, count: 480, at: press.advanced(by: .milliseconds(20 * index)), rate: rate)
    }
    let frames = try #require(sink.take())
    let recording = try #require(frames.recording(releasedAt: press.advanced(by: .seconds(1))))
    #expect(abs(recording.samples.count - 16_000) <= 1)
    #expect(abs(recording.keptDuration / .microseconds(1) - 1_000_000) < 50)
    #expect(frames.droppedChunks == 0)
  }

  @Test func `a chunk at another rate is dropped and the recording keeps its samples`() throws {
    let sink = FrameSink()
    sink.begin(RawFrames(press: press, sampleRate: rate, reservingSeconds: 1))
    deliver(sink, count: 480, at: press, rate: rate)
    deliver(sink, count: 960, at: press.advanced(by: .milliseconds(20)), rate: 48_000)
    deliver(sink, count: 480, at: press.advanced(by: .milliseconds(20)), rate: rate)
    let frames = try #require(sink.take())
    #expect(frames.samples.count == 960)
    #expect(frames.droppedChunks == 1)
    let recording = try #require(frames.recording(releasedAt: press.advanced(by: .milliseconds(40))))
    #expect(abs(recording.keptDuration / .microseconds(1) - 40_000) < 50)
  }

  @Test func `a recording whose every chunk had another rate fails instead of coming back empty`() async {
    let recorder = Recorder()
    recorder.sink.begin(RawFrames(press: press, sampleRate: rate, reservingSeconds: 1))
    deliver(recorder.sink, count: 960, at: press, rate: 48_000)
    await #expect(throws: CaptureError.captureFailed) {
      try await recorder.finishRecording(releasedAt: press.advanced(by: .milliseconds(20)))
    }
  }

  @Test(arguments: [48_000.0, 44_100.0, 24_000.0])
  func `the recording so far is a prefix of the recording at the release`(rate: Double) throws {
    let sink = FrameSink()
    sink.begin(RawFrames(press: press, sampleRate: rate, reservingSeconds: 3))
    let chunk = Int(rate / 50)
    var soFar: [Float]?
    for index in 0..<100 {
      var samples = (0..<chunk).map {
        Float(0.3 * sin(Double(index * chunk + $0) * 0.05)) + Float.random(in: -0.05...0.05)
      }
      samples.withUnsafeMutableBufferPointer { buffer in
        var list = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(chunk * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(buffer.baseAddress)))
        withUnsafePointer(to: &list) {
          sink.receive(list: $0, frames: chunk, at: press.advanced(by: .milliseconds(20 * index)), rate: rate)
        }
      }
      if index == 61, let raw = sink.soFar() {
        soFar = SpeechResampler.settledPrefix(raw.samples[...], from: rate)
      }
    }
    let prefix = try #require(soFar)
    let frames = try #require(sink.take())
    let recording = try #require(frames.recording(releasedAt: press.advanced(by: .seconds(2))))
    #expect(prefix.count > 19_800)
    #expect(Array(recording.samples.prefix(prefix.count)) == prefix)
  }

  @Test func `nothing is kept when no recording is open`() {
    let sink = FrameSink()
    deliver(sink, count: 480, at: press, rate: rate)
    #expect(sink.take() == nil)
  }
}
