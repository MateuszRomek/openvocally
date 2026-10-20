import Models
import Synchronization
import Transcription

/// Returns at once and records every input it is given, so `--plan` shows what the runtime
/// decodes for a recording without loading a model.
final class PlanTranscriber: Transcriber {
  struct Call {
    let input: [Float]
    let atRelease: Bool
  }

  let lookahead: Lookahead
  private let state = Mutex((calls: [Call](), released: false))

  init(lookahead: Lookahead) {
    self.lookahead = lookahead
  }

  var calls: [Call] { state.withLock { $0.calls } }

  func release() {
    state.withLock { $0.released = true }
  }

  func transcribe(_ samples: [Float]) async throws(TranscriptionError) -> String {
    state.withLock { $0.calls.append(Call(input: samples, atRelease: $0.released)) }
    return "\(samples.count)"
  }
}

struct PlannedInputs: Equatable {
  var early: [Range<Int>]
  var release: [Range<Int>]
}

/// Plays `samples` at the settled pace into the shipping runtime with `lookahead`, releases, and
/// reports where each engine input sits in the recording.
func planInputs(_ samples: [Float], lookahead: Lookahead) async throws -> PlannedInputs {
  let engine = PlanTranscriber(lookahead: lookahead)
  let strategy = try await ShippingStrategy<PlanModel>(engine: engine)
  await strategy.start()
  for chunkStart in stride(from: 0, to: samples.count, by: chunkSamples) {
    await strategy.append(Array(samples[chunkStart..<min(chunkStart + chunkSamples, samples.count)]))
  }
  try await strategy.settle(timeout: Pace.settleTimeout)
  engine.release()
  do {
    _ = try await strategy.finish()
  } catch TranscriptionError.noSpeech {}
  var inputs = PlannedInputs(early: [], release: [])
  for call in engine.calls {
    let range = locate(call.input, in: samples)
    if call.atRelease { inputs.release.append(range) } else { inputs.early.append(range) }
  }
  return inputs
}

/// The first place `input` appears in `samples`. Engine inputs are slices of the recording.
private func locate(_ input: [Float], in samples: [Float]) -> Range<Int> {
  guard let first = input.first else { return 0..<0 }
  let start =
    (0...(samples.count - input.count)).first { index in
      samples[index] == first && samples[index..<index + input.count].elementsEqual(input)
    } ?? 0
  return start..<start + input.count
}

func planLine(_ id: String, _ inputs: PlannedInputs, width: Int) -> String {
  func seconds(_ ranges: [Range<Int>]) -> String {
    guard !ranges.isEmpty else { return "-" }
    return ranges.map { range in
      String(format: "%.2f-%.2f", Double(range.lowerBound) / 16_000, Double(range.upperBound) / 16_000)
    }.joined(separator: ", ")
  }
  let name = id.padding(toLength: max(width, id.count), withPad: " ", startingAt: 0)
  return "\(name)  early: \(seconds(inputs.early))  release: \(seconds(inputs.release))"
}

/// Only satisfies `ShippingStrategy`'s generic parameter; `--plan` builds the strategy from an engine.
struct PlanModel: WholeBufferTranscriber {
  let engine: any Transcriber

  func transcribeAll(_ samples: [Float]) async throws -> String {
    try await engine.transcribe(samples)
  }
}

extension ModelID {
  /// The engine's own lookahead, read without loading the model.
  var lookahead: Lookahead {
    switch engine {
    case .parakeet: ParakeetTranscriber.lookahead
    case .whisper: WhisperTranscriber.lookahead
    case .apple: .off
    }
  }
}

/// `--plan`: every selected model and fixture, fixtures planned concurrently. Models whose
/// engines share a lookahead share one plan.
func printPlans(models: [ModelID], fixtures: [Fixture]) async throws {
  let width = fixtures.map(\.id.count).max() ?? 0
  var planned: [(lookahead: Lookahead, plans: [Int: PlannedInputs])] = []
  for model in models {
    let lookahead = model.lookahead
    let plans: [Int: PlannedInputs]
    if let shared = planned.first(where: { $0.lookahead == lookahead }) {
      plans = shared.plans
    } else {
      plans = try await plan(fixtures, lookahead)
      planned.append((lookahead, plans))
    }
    print(model.benchName)
    for (index, fixture) in fixtures.enumerated() {
      if let plan = plans[index] { print("  " + planLine(fixture.id, plan, width: width)) }
    }
  }
}

private func plan(_ fixtures: [Fixture], _ lookahead: Lookahead) async throws -> [Int: PlannedInputs] {
  try await withThrowingTaskGroup(of: (Int, PlannedInputs).self) { group in
    for (index, fixture) in fixtures.enumerated() {
      group.addTask { (index, try await planInputs(fixture.samples, lookahead: lookahead)) }
    }
    return try await group.reduce(into: [Int: PlannedInputs]()) { $0[$1.0] = $1.1 }
  }
}
