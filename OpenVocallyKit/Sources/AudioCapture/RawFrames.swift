import AVFoundation
import CoreAudio
import DictationCore

struct RawFrames {
  private(set) var press: HostTime
  let sampleRate: Double
  private(set) var samples: [Float] = []
  private(set) var firstChunkAt: HostTime?
  private(set) var lastChunkAt: HostTime?
  private(set) var lastChunkIndex = 0
  /// Chunks refused because their rate or layout did not match. Never converted on the
  /// delivery thread.
  private(set) var droppedChunks = 0

  /// Touches every reserved page here, so the IO thread never page-faults into the buffer.
  init(press: HostTime, sampleRate: Double, reservingSeconds: Double = 120) {
    self.press = press
    self.sampleRate = sampleRate
    let capacity = Int(sampleRate * reservingSeconds)
    samples.reserveCapacity(capacity)
    samples.append(contentsOf: repeatElement(0, count: capacity))
    samples.removeAll(keepingCapacity: true)
  }

  mutating func scrub() {
    samples.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    samples.removeAll(keepingCapacity: true)
  }

  mutating func reset(press: HostTime) {
    self.press = press
    samples.removeAll(keepingCapacity: true)
    firstChunkAt = nil
    lastChunkAt = nil
    lastChunkIndex = 0
    droppedChunks = 0
  }

  mutating func noteDropped() {
    droppedChunks += 1
  }

  func copyNewest(into destination: UnsafeMutableBufferPointer<Float>) {
    let count = min(destination.count, samples.count)
    let padding = destination.count - count
    destination[..<padding].update(repeating: 0)
    samples.withUnsafeBufferPointer { source in
      guard count > 0, let base = source.baseAddress, let target = destination.baseAddress else { return }
      (target + padding).update(from: base + (source.count - count), count: count)
    }
  }

  var coveredUntil: HostTime? {
    lastChunkAt?.advanced(bySeconds: Double(samples.count - lastChunkIndex) / sampleRate)
  }

  /// Real-time safe while capacity lasts: no allocation, locks or logging.
  mutating func append(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, at start: HostTime) {
    var channels = 0
    for buffer in list { channels += Int(buffer.mNumberChannels) }
    guard channels > 0, frames > 0 else { return }
    if firstChunkAt == nil { firstChunkAt = start }
    lastChunkAt = start
    lastChunkIndex = samples.count
    let scale = 1 / Float(channels)
    for frame in 0..<frames {
      var sum: Float = 0
      for buffer in list {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let stride = Int(buffer.mNumberChannels)
        let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(stride, 1))
        guard frame < available else { continue }
        for channel in 0..<stride { sum += data[frame * stride + channel] }
      }
      samples.append(sum * scale)
    }
  }

  /// First sample at or after the press. Fixed once the first chunk arrived.
  var keptStart: Int {
    guard let firstChunkAt, firstChunkAt < press else { return 0 }
    return Int((press.seconds(since: firstChunkAt) * sampleRate).rounded(.up))
  }

  /// Copies the kept samples from the press on into `destination`, as many as fit, and returns
  /// how many it copied.
  func copyKept(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
    let start = min(keptStart, samples.count)
    let count = min(destination.count, samples.count - start)
    samples.withUnsafeBufferPointer { source in
      guard count > 0, let base = source.baseAddress, let target = destination.baseAddress else { return }
      target.update(from: base + start, count: count)
    }
    return max(count, 0)
  }

  func keptRange(releasedAt release: HostTime) -> Range<Int> {
    guard firstChunkAt != nil, let lastChunkAt else { return 0..<0 }
    let start = keptStart
    let end = lastChunkIndex + Int((release.seconds(since: lastChunkAt) * sampleRate).rounded())
    let clampedStart = min(start, samples.count)
    return clampedStart..<min(max(end, clampedStart), samples.count)
  }

  func recording(releasedAt release: HostTime) -> Recording? {
    let kept = keptRange(releasedAt: release)
    let keptDuration = Duration.nanoseconds(Int64((Double(kept.count) / sampleRate * 1e9).rounded()))
    guard let firstChunkAt, !kept.isEmpty else {
      return Recording(samples: [], firstSampleOffset: nil, keptDuration: .zero)
    }
    guard let converted = SpeechResampler.convert(samples[kept], from: sampleRate) else { return nil }
    let firstKeptAt = firstChunkAt.advanced(bySeconds: Double(kept.lowerBound) / sampleRate)
    let offset = max(.zero, firstKeptAt.duration(since: press))
    return Recording(samples: converted, firstSampleOffset: offset, keptDuration: keptDuration)
  }
}
