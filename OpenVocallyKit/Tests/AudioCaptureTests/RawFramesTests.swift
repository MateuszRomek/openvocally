import AVFoundation
import CoreMedia
import DictationCore
import Foundation
import Testing

@testable import AudioCapture

private func withChunk<R>(
  _ channels: [[Float]], _ body: (UnsafeMutableAudioBufferListPointer, Int) -> R
) -> R {
  let list = AudioBufferList.allocate(maximumBuffers: channels.count)
  defer { free(list.unsafeMutablePointer) }
  let storage = channels.map { channel in
    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
    pointer.initialize(from: channel, count: channel.count)
    return pointer
  }
  defer { for pointer in storage { pointer.deallocate() } }
  for (index, channel) in channels.enumerated() {
    list[index] = AudioBuffer(
      mNumberChannels: 1, mDataByteSize: UInt32(channel.count * MemoryLayout<Float>.size),
      mData: UnsafeMutableRawPointer(storage[index]))
  }
  return body(list, channels.first?.count ?? 0)
}

struct RawFramesTests {
  private let rate = 48_000.0

  private func ramp(_ count: Int, from start: Int) -> [Float] { (start..<start + count).map(Float.init) }

  private func frames(chunks: Int, lead: Duration) -> RawFrames {
    var frames = RawFrames(press: press, sampleRate: rate, reservingSeconds: 1)
    let first = press.advanced(by: .zero - lead)
    for index in 0..<chunks {
      withChunk([ramp(512, from: index * 512)]) { list, count in
        frames.append(list, frames: count, at: first.advanced(bySeconds: Double(index * 512) / rate))
      }
    }
    return frames
  }

  @Test func `trims at the press and at the release inside chunks`() throws {
    let frames = frames(chunks: 10, lead: .milliseconds(5))
    let release = press.advanced(by: .milliseconds(60))
    #expect(frames.keptRange(releasedAt: release) == 240..<3120)
    let recording = try #require(frames.recording(releasedAt: release))
    #expect(abs(recording.keptDuration / .microseconds(1) - 60_000) < 25)
    #expect(abs(recording.samples.count - 960) <= 1)
    let offset = try #require(recording.firstSampleOffset)
    #expect(offset >= .zero && offset < .microseconds(25))
  }

  @Test func `a release past the captured frames keeps everything after the press`() {
    let frames = frames(chunks: 2, lead: .zero)
    #expect(frames.keptRange(releasedAt: press.advanced(by: .seconds(1))) == 0..<1024)
    #expect(frames.coveredUntil.map { abs($0.milliseconds(since: press) - 1024 / 48) < 0.01 } == true)
  }

  @Test func `cold start reports the gap to the first sample`() throws {
    var frames = RawFrames(press: press, sampleRate: rate, reservingSeconds: 1)
    withChunk([ramp(512, from: 0)]) { list, count in
      frames.append(list, frames: count, at: press.advanced(by: .milliseconds(45)))
    }
    let recording = try #require(frames.recording(releasedAt: press.advanced(by: .seconds(1))))
    let offset = try #require(recording.firstSampleOffset)
    #expect(abs((offset - .milliseconds(45)) / .microseconds(1)) < 1)
  }

  @Test func `a reset buffer trims to the new press and keeps its capacity`() throws {
    var reused = frames(chunks: 10, lead: .milliseconds(5))
    let capacity = reused.samples.capacity
    let nextPress = press.advanced(by: .seconds(10))
    reused.reset(press: nextPress)
    withChunk([ramp(512, from: 0)]) { list, count in
      reused.append(list, frames: count, at: nextPress.advanced(by: .milliseconds(30)))
    }
    #expect(reused.samples.capacity == capacity)
    #expect(reused.keptRange(releasedAt: nextPress.advanced(by: .seconds(1))) == 0..<512)
    let recording = try #require(reused.recording(releasedAt: nextPress.advanced(by: .seconds(1))))
    let offset = try #require(recording.firstSampleOffset)
    #expect(abs((offset - .milliseconds(30)) / .microseconds(1)) < 1)
  }

  @Test func `nothing kept means no offset`() throws {
    let frames = frames(chunks: 1, lead: .milliseconds(20))
    let recording = try #require(frames.recording(releasedAt: press.advanced(by: .milliseconds(30))))
    #expect(recording.samples.isEmpty)
    #expect(recording.firstSampleOffset == nil)
    #expect(recording.keptDuration == .zero)
  }

  @Test func `downmixes a two-channel chunk by averaging`() {
    var frames = RawFrames(press: press, sampleRate: rate, reservingSeconds: 1)
    withChunk([[1, 0, -1, 0.5], [0, 0, 1, 0.5]]) { list, count in
      frames.append(list, frames: count, at: press)
    }
    #expect(frames.samples == [0.5, 0, 0, 0.5])
  }
}
