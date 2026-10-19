import Foundation
import Models
import Transcription

/// Runs the bench. Returns false when a run or a model load failed.
@MainActor
func bench(_ options: Options, arguments: [String]) async throws -> Bool {
  let catalog = try fixtureCatalog()
  let fixtureIDs: [String] =
    switch options.fixtures {
    case .standard: defaultFixtures
    case .all: catalog.map(\.id)
    case .named(let ids): ids
    }
  let fixtures = try fixtureIDs.map { id in
    guard let entry = catalog.first(where: { $0.id == id }) else {
      throw BenchError("unknown fixture \(id); known: \(catalog.map(\.id).joined(separator: ", "))")
    }
    return try loadFixture(id: entry.id, wav: entry.wav, reference: entry.reference)
  }
  let requested = try (options.models ?? ModelID.benchNames).map { name in
    guard let bench = benches.first(where: { $0.model.benchName == name }) else {
      throw BenchError("unknown model \(name); known: \(ModelID.benchNames.joined(separator: ", "))")
    }
    return bench
  }
  let known = Set(benches.flatMap(\.strategyNames))
  for name in options.strategies ?? [] where !known.contains(name) {
    throw BenchError("unknown strategy \(name); known: \(known.sorted().joined(separator: ", "))")
  }
  if options.plan {
    try await printPlans(models: requested.map(\.model), fixtures: fixtures)
    return true
  }

  let out =
    options.out.map { URL(filePath: $0, directoryHint: .isDirectory) }
    ?? packageRoot.appending(path: "results/\(timestamp())", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  let session = Session(
    options: options, fixtures: fixtures, writer: try JSONLWriter(file: out.appending(path: "results.jsonl")))
  var meta = Meta.current(arguments: arguments)
  try meta.write(to: out.appending(path: "meta.json"))

  let folders = modelFolders(first: options.modelDirectory)
  var records: [RunRecord] = []
  var failed = false
  for bench in requested {
    let name = bench.model.benchName
    guard let location = installedLocation(of: bench.model, in: folders) else {
      print("skip \(name): not installed in \(folders.map(\.root.path).joined(separator: ", "))")
      meta.models.append(.init(model: name, status: "not installed"))
      continue
    }
    let strategies = bench.strategyNames.filter { options.strategies?.contains($0) ?? true }
    guard !strategies.isEmpty else {
      print("skip \(name): no requested strategy is registered for its engine")
      meta.models.append(.init(model: name, status: "no strategy", location: location.path))
      continue
    }
    do {
      // Held from the load to the last run, so a concurrent bench never times on a loaded machine.
      let lock = try BenchLock(path: options.lockPath)
      let timed = try await bench.run(location, strategies, session)
      withExtendedLifetime(lock) {}
      records += timed
      let failures = timed.filter { $0.error != nil }.count
      if failures > 0 { failed = true }
      meta.models.append(
        .init(model: name, status: failures > 0 ? "\(failures) runs failed" : "ok", location: location.path))
    } catch {
      failed = true
      print("fail \(name): \(error)")
      meta.models.append(.init(model: name, status: "failed", location: location.path, detail: "\(error)"))
    }
  }

  let rows = summarize(records)
  try summaryTSV(rows).write(to: out.appending(path: "summary.tsv"), atomically: true, encoding: .utf8)
  meta.finishedAt = .now
  meta.thermalAtEnd = thermalState()
  try meta.write(to: out.appending(path: "meta.json"))
  print(summaryTable(rows))
  print(tierNote)
  print("results: \(out.path)")
  return !failed
}

func timestamp() -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  return formatter.string(from: .now)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
  let options = try Options(arguments)
  if options.help {
    let strategies = Dictionary(
      benches.map { ($0.model.engine.rawValue, $0.strategyNames) }, uniquingKeysWith: { first, _ in first })
    print(usage(strategies: strategies, fixtures: try fixtureCatalog().map(\.id)))
    exit(0)
  }
  exit(try await bench(options, arguments: arguments) ? 0 : 1)
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(2)
}
