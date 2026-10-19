#if DEBUG
  import AVFAudio
  import Foundation
  import Synchronization

  /// Stands in for the microphone: plays a WAV file in real time from the press, in the format
  /// the live capture returns (16 kHz mono Float).
  final class FixtureCapture: Sendable {
    enum LoadError: Error {
      case unsupportedFormat(sampleRate: Double, channels: UInt32)
      case unreadable
    }

    static let sampleRate = 16_000.0

    private struct State {
      var samples: [Float] = []
      var startedAt: ContinuousClock.Instant?
    }

    private let state = Mutex(State())

    static func samples(of url: URL) throws -> [Float] {
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      guard format.sampleRate == sampleRate, format.channelCount == 1 else {
        throw LoadError.unsupportedFormat(sampleRate: format.sampleRate, channels: format.channelCount)
      }
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
      else { throw LoadError.unreadable }
      try file.read(into: buffer)
      guard let channel = buffer.floatChannelData?[0] else { throw LoadError.unreadable }
      return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// The fixture the next press plays.
    func load(_ samples: [Float]) {
      state.withLock { $0 = State(samples: samples) }
    }

    func start() {
      state.withLock { $0.startedAt = .now }
    }

    /// The part of the fixture played since the press, nil when nothing plays.
    func soFar() -> [Float]? {
      state.withLock { state in
        guard let startedAt = state.startedAt else { return nil }
        let seconds = (ContinuousClock.now - startedAt) / .seconds(1)
        let count = min(state.samples.count, Int(seconds * Self.sampleRate))
        return Array(state.samples.prefix(count))
      }
    }

    /// The whole fixture: the harness holds the key for its full length.
    func stop() -> [Float] {
      state.withLock { state in
        state.startedAt = nil
        return state.samples
      }
    }

    func cancel() {
      state.withLock { $0.startedAt = nil }
    }
  }
#endif
