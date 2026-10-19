import Foundation

enum Pace: String, Sendable {
  /// Each 20 ms chunk is appended once its 20 ms of audio would have been recorded.
  case realtime
  /// Chunks are appended back to back.
  case instant
  /// Chunks are appended back to back, then the release waits until the runtime has finished
  /// all the work it would do on the recording before the release, so the release sees what a
  /// realtime run sees in a fraction of the time.
  case settled

  static let settleTimeout = Duration.seconds(60)
}

let chunkSamples = 320  // 20 ms at 16 kHz

struct Measurement {
  var releaseToText: Duration
  var appendBusy: Duration
  var maxLag: Duration
  var fellBehind: Bool
  var result: Result<String, any Error>
}

/// Plays `samples` into `strategy` and times the release. Release is the moment the last `append`
/// returns; the clock stops when `finish` returns. `leadIn` passes between the press (`start`) and
/// the first sample, which moves the release against work the strategy repeats on a timer.
func feed<Model>(
  _ samples: [Float], into strategy: any Strategy<Model>, pace: Pace, leadIn: Duration = .zero
) async -> Measurement {
  await strategy.start()
  try? await Task.sleep(for: leadIn)
  let clock = ContinuousClock()
  let begin = clock.now
  var busy = Duration.zero
  var maxLag = Duration.zero
  for chunkStart in stride(from: 0, to: samples.count, by: chunkSamples) {
    let chunkEnd = min(chunkStart + chunkSamples, samples.count)
    if pace == .realtime {
      // A chunk is available once its last sample was recorded.
      let available = begin + .microseconds(Int64(chunkEnd) * 1_000_000 / 16_000)
      let now = clock.now
      if now < available {
        try? await clock.sleep(until: available, tolerance: .microseconds(500))
      } else {
        maxLag = max(maxLag, now - available)
      }
    }
    let before = clock.now
    await strategy.append(Array(samples[chunkStart..<chunkEnd]))
    busy += clock.now - before
  }
  if pace == .settled {
    do {
      try await strategy.settle(timeout: Pace.settleTimeout)
    } catch {
      return Measurement(
        releaseToText: .zero, appendBusy: busy, maxLag: maxLag, fellBehind: false, result: .failure(error))
    }
  }
  let release = clock.now
  let audioEnd = begin + .microseconds(Int64(samples.count) * 1_000_000 / 16_000)
  let fellBehind = pace == .realtime && release - audioEnd > .milliseconds(20)
  let result: Result<String, any Error>
  do {
    result = .success(try await strategy.finish())
  } catch {
    result = .failure(error)
  }
  let done = clock.now
  return Measurement(
    releaseToText: done - release, appendBusy: busy, maxLag: maxLag, fellBehind: fellBehind,
    result: result)
}

extension Duration {
  var milliseconds: Double { self / .milliseconds(1) }
}
