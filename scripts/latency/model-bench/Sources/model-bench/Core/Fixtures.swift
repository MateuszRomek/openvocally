import AVFoundation
import Foundation

struct Fixture: Sendable {
  let id: String
  let reference: String
  let samples: [Float]

  var seconds: Double { Double(samples.count) / 16_000 }
}

/// The repository root, found from this source file's compile-time path.
/// The file sits at scripts/latency/model-bench/Sources/model-bench/Core/, seven levels down.
let repositoryRoot = (0..<7).reduce(URL(filePath: #filePath)) { url, _ in url.deletingLastPathComponent() }

let packageRoot = repositoryRoot.appending(path: "scripts/latency/model-bench")

/// Where fixtures come from, searched in order: this bench's own, then the shared set.
/// Each source has a tsv whose first column is the id and last column the reference text. An empty
/// or `-` reference means no speech is expected: the right output is no text.
private let fixtureSources = [
  (wavs: packageRoot.appending(path: "fixtures"), tsv: packageRoot.appending(path: "fixtures/fixtures.tsv")),
  (
    wavs: repositoryRoot.appending(path: "scripts/fixtures"),
    tsv: repositoryRoot.appending(path: "scripts/fixtures/fixtures.tsv")
  ),
]

/// The fixtures a run uses when `--fixtures` is not given.
let defaultFixtures = [
  "en-short", "en-noisy", "pl-short", "en-1s", "pl-1s", "en-quiet-end", "noise-3s", "silence", "pl-numbers",
  "en-15s", "en-30s",
]

/// Every fixture id with a WAV and a reference, mapped to its WAV and reference text.
func fixtureCatalog() throws -> [(id: String, wav: URL, reference: String)] {
  var catalog: [(id: String, wav: URL, reference: String)] = []
  for source in fixtureSources {
    let rows = try String(contentsOf: source.tsv, encoding: .utf8).split(separator: "\n").dropFirst()
    for row in rows {
      let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
      guard columns.count >= 3, let id = columns.first.map(String.init), let text = columns.last else {
        continue
      }
      let reference = text == "-" ? "" : String(text)
      let wav = source.wavs.appending(path: "\(id).wav")
      guard !catalog.contains(where: { $0.id == id }),
        FileManager.default.fileExists(atPath: wav.path)
      else { continue }
      catalog.append((id, wav, reference))
    }
  }
  return catalog
}

func loadFixture(id: String, wav: URL, reference: String) throws -> Fixture {
  let audio = try AVAudioFile(forReading: wav)
  let format = audio.processingFormat
  guard format.sampleRate == 16_000, format.channelCount == 1,
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length))
  else { throw BenchError("\(id).wav is not 16 kHz mono") }
  try audio.read(into: buffer)
  guard let channel = buffer.floatChannelData?[0] else {
    throw BenchError("\(id).wav did not decode to float samples")
  }
  let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  return Fixture(id: id, reference: reference, samples: samples)
}

struct BenchError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
