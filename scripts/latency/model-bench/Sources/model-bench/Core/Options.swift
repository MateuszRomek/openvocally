import Foundation
import Models
import Transcription

/// The command line. `nil` lists mean the default: every installed model, every registered
/// strategy, the five standard fixtures.
struct Options: Equatable {
  enum FixtureChoice: Equatable {
    case standard
    case all
    case named([String])
  }

  var models: [String]?
  var strategies: [String]?
  var fixtures = FixtureChoice.standard
  var runs = 20
  /// Runs for fixtures at least `longSeconds` long. Defaults to half of `runs`.
  var longRuns: Int?
  var longSeconds = 10.0
  var pace = Pace.realtime
  var gapMs = 500
  /// Quiet appended to each fixture before the release, like a user who stops talking and then
  /// lets go of the key.
  var releaseGapMs = 0
  var out: String?
  var modelDirectory: String?
  var lockPath = BenchLock.defaultPath
  var help = false
  var plan = false

  var effectiveLongRuns: Int { longRuns ?? max(1, runs / 2) }

  init() {}

  init(_ arguments: [String]) throws {
    var iterator = arguments.makeIterator()
    func value(_ flag: String) throws -> String {
      guard let next = iterator.next(), !next.hasPrefix("--") else {
        throw BenchError("\(flag) needs a value")
      }
      return next
    }
    func list(_ flag: String) throws -> [String]? {
      let items = try value(flag).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      return items == ["all"] ? nil : items
    }
    func count(_ flag: String) throws -> Int {
      guard let number = Int(try value(flag)), number > 0 else {
        throw BenchError("\(flag) needs a positive number")
      }
      return number
    }
    while let flag = iterator.next() {
      switch flag {
      case "--help", "-h": help = true
      case "--plan": plan = true
      case "--models": models = try list(flag)
      case "--strategies": strategies = try list(flag)
      case "--fixtures": fixtures = try list(flag).map(FixtureChoice.named) ?? .all
      case "--runs": runs = try count(flag)
      case "--long-runs": longRuns = try count(flag)
      case "--long-seconds":
        guard let seconds = Double(try value(flag)), seconds > 0 else {
          throw BenchError("--long-seconds needs a positive number")
        }
        longSeconds = seconds
      case "--pace":
        guard let pace = Pace(rawValue: try value(flag)) else {
          throw BenchError("--pace is realtime, instant or settled")
        }
        self.pace = pace
      case "--gap-ms": gapMs = try count(flag)
      case "--release-gap-ms": releaseGapMs = try count(flag)
      case "--out": out = try value(flag)
      case "--model-dir": modelDirectory = try value(flag)
      case "--lock": lockPath = try value(flag)
      default: throw BenchError("unknown argument \(flag); see --help")
      }
    }
  }
}

func usage(strategies: [String: [String]], fixtures: [String]) -> String {
  let registered = strategies.sorted { $0.key < $1.key }.map {
    "\($0.key): \($0.value.joined(separator: ", "))"
  }
  return """
    model-bench [--models <ids>|all] [--strategies <names>|all] [--fixtures <ids>|all] [--runs <n>]
                [--long-runs <n>] [--pace realtime|instant|settled] [--out <dir>] [--model-dir <dir>]
                [--gap-ms <ms>] [--release-gap-ms <ms>] [--long-seconds <s>] [--lock <path>] [--plan]

      Times push-to-talk release to final text for each local model and strategy. Each fixture is
      played into the strategy in 20 ms chunks; the clock starts when the last chunk is appended
      (release) and stops when the strategy returns its text. One warmup run per strategy and
      fixture is discarded. Each model loads once, before its warmup, and is released before the
      next model loads.

      --models       \(ModelID.benchNames.joined(separator: ", ")) (default: every installed model;
                     missing ones are skipped with a note)
      --strategies   default: every registered strategy of each model's engine
      --fixtures     default: \(defaultFixtures.joined(separator: ",")); all = every fixture listed below
      --runs         timed runs per fixture under --long-seconds (default 20)
      --long-runs    timed runs per fixture of --long-seconds or more (default: half of --runs)
      --long-seconds default 10
      --pace         realtime (default): one chunk every 20 ms, as a microphone delivers them.
                     instant: back to back. settled: back to back, then the release waits until the
                     runtime has finished its work on the recording (fast iteration; compare final
                     numbers with realtime)
      --plan         loads no model; prints, per model and fixture, the inputs the runtime starts
                     while recording and the inputs the release decodes
      --out          results folder (default: scripts/latency/model-bench/results/<timestamp>)
      --model-dir    a local-models folder to search first. Default search: the Release app, then the
                     Debug app (both under ~/Library/Application Support)
      --gap-ms       idle pause before each run (default 500)
      --release-gap-ms  digital silence appended to each fixture before the release, a user who
                     stops talking and then lets go of the key (default 0)
      --lock         flock file held while a model loads and is timed (default \(BenchLock.defaultPath))

      Writes results.jsonl (one line per timed run), summary.tsv and meta.json to --out.
      Exits 0 when every run succeeded, 1 when a run or a model load failed, 2 on a usage error.

    Registered strategies:
    \(registered.map { "  " + $0 }.joined(separator: "\n"))

    Fixtures:
      \(fixtures.joined(separator: ", "))
    """
}
