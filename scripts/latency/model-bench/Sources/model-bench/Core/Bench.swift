import Foundation
import Models
import Transcription

extension ModelID {
  /// The name used on the command line and in results: the case name, for example `parakeetV3`.
  var benchName: String { String(describing: self) }

  static var benchNames: [String] { allCases.filter { $0.hosted != nil }.map(\.benchName) }

  var hosted: HostedModel? {
    switch provider {
    case .hosted(let hosted): hosted
    case .system: nil
    }
  }
}

/// What one timed session needs, shared by every model.
struct Session {
  let options: Options
  let fixtures: [Fixture]
  let writer: JSONLWriter
}

/// One model with its loader and strategies, with the model type erased so models of different
/// engines sit in one list.
struct ModelBench {
  let model: ModelID
  let strategyNames: [String]
  /// Loads the model, runs the named strategies over every fixture, and returns the timed runs.
  /// The model is released when this returns.
  let run:
    @MainActor (_ location: URL, _ strategies: [String], _ session: Session) async throws -> [RunRecord]

  init<Model: Sendable>(
    _ model: ModelID, strategies: [any Strategy<Model>.Type],
    load: @escaping @Sendable (URL) async throws -> Model
  ) {
    self.model = model
    strategyNames = strategies.map { $0.name }
    run = { location, names, session in
      let clock = ContinuousClock()
      let start = clock.now
      let loaded = try await load(location)
      log(
        "loaded \(model.benchName) in \(Int((clock.now - start) / .milliseconds(1))) ms from \(location.path)"
      )
      var records: [RunRecord] = []
      for type in strategies where names.contains(type.name) {
        let strategy = try await type.init(model: loaded)
        records += try await time(strategy, named: type.name, model: model, session: session)
      }
      return records
    }
  }
}

/// One discarded warmup run, then the timed runs, for every fixture.
@MainActor
private func time<Model>(
  _ strategy: any Strategy<Model>, named name: String, model: ModelID, session: Session
) async throws -> [RunRecord] {
  var records: [RunRecord] = []
  let options = session.options
  for fixture in session.fixtures {
    let runs = fixture.seconds >= options.longSeconds ? options.effectiveLongRuns : options.runs
    for run in 0...runs {
      try await Task.sleep(for: .milliseconds(options.gapMs))
      let samples = fixture.samples + repeatElement(0, count: options.releaseGapMs * 16)
      // The runtime pings the engine about once a second while recording, and every run
      // of a fixture has the same length, so a fixed lead-in would hit the same ping phase.
      let leadIn = Duration.milliseconds(run % 10 * 100)
      let measurement = await feed(samples, into: strategy, pace: options.pace, leadIn: leadIn)
      var record = RunRecord(
        model: model.benchName, strategy: name, fixture: fixture.id, pace: options.pace.rawValue,
        audioSeconds: fixture.seconds, run: run, releaseToTextMs: measurement.releaseToText.milliseconds,
        appendBusyMs: measurement.appendBusy.milliseconds, maxAppendLagMs: measurement.maxLag.milliseconds,
        fellBehind: measurement.fellBehind, thermal: thermalState(), text: "", wer: nil, error: nil,
        releaseGapMs: options.releaseGapMs)
      switch measurement.result {
      case .success(let text):
        record.score(text, reference: fixture.reference)
      case .failure(TranscriptionError.noSpeech):
        record.score("", reference: fixture.reference)
      case .failure(let error):
        record.error = String(describing: error)
      }
      let label = run == 0 ? "warmup" : "run \(run)/\(runs)"
      let outcome = record.error.map { "error \($0)" } ?? String(format: "wer %.3f", record.wer ?? 0)
      log(
        "\(model.benchName) \(name) \(fixture.id) \(label): \(String(format: "%.1f", record.releaseToTextMs)) ms \(outcome)"
      )
      guard run > 0 else { continue }
      try session.writer.write(record)
      records.append(record)
    }
  }
  return records
}

/// The folders searched for installed models, in order: `--model-dir`, the Release app, then the
/// Debug app.
func modelFolders(first: String?) -> [ModelFolder] {
  let roots = ["com.openvocally.app", "com.openvocally.app.debug"].map {
    URL.applicationSupportDirectory.appending(path: $0, directoryHint: .isDirectory)
      .appending(path: "local-models", directoryHint: .isDirectory)
  }
  return ((first.map { [URL(filePath: $0, directoryHint: .isDirectory)] } ?? []) + roots).map {
    ModelFolder(root: $0)
  }
}

/// The first folder holding a complete copy of `model`, by the shipping manifest's file sizes.
func installedLocation(of model: ModelID, in folders: [ModelFolder]) -> URL? {
  guard let hosted = model.hosted else { return nil }
  return folders.first { $0.isInstalled(hosted) }?.location(of: hosted)
}
