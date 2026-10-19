import Foundation
import Testing

@testable import DictationCore
@testable import Storage

private let start = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 86_400

private func files(_ folder: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func writeFailed(_ id: String, failedAt: Date, in root: URL) throws {
  let failed = root.appending(path: "failed")
  try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
  try Data().write(to: failed.appending(path: "\(id).wav"))
  let metadata = RecordingArchive.FailureMetadata(
    failedAt: unixMilliseconds(failedAt), reason: "noSpeech", startedAt: nil, sampleRate: 16_000)
  try JSONEncoder().encode(metadata).write(to: failed.appending(path: "\(id).json"))
}

struct RecordingArchiveTests {
  @Test func keepThenDiscardLeavesNothing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecordingArchive(root: root, now: { start })
    await archive.prepare()
    let sink = archive.sink
    await sink.keep(SessionID(raw: 1), [0, 0.5, -0.5])
    #expect(try files(root.appending(path: "active")).count == 1)
    await sink.discard(SessionID(raw: 1))
    #expect(try files(root.appending(path: "active")).isEmpty)
    #expect(try files(root.appending(path: "failed")).isEmpty)
  }

  @Test func keepThenFailLeavesAudioAndMetadata() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecordingArchive(root: root, now: { start })
    await archive.prepare()
    await archive.keep(SessionID(raw: 1), [0.25, -1])
    await archive.fail(SessionID(raw: 1), .captureError(.deviceLost))
    #expect(try files(root.appending(path: "active")).isEmpty)
    let failed = try files(root.appending(path: "failed"))
    #expect(failed.count == 2)
    let json = try #require(failed.first { $0.hasSuffix(".json") })
    let metadata = try JSONDecoder().decode(
      RecordingArchive.FailureMetadata.self, from: Data(contentsOf: root.appending(path: "failed/\(json)")))
    #expect(
      metadata == .init(failedAt: 1_700_000_000_000, reason: "captureError.deviceLost", sampleRate: 16_000))
    let wav = try Data(contentsOf: root.appending(path: "failed/\(json.dropLast(5)).wav"))
    #expect(wav.count == 44 + 8)
    #expect(wav.prefix(4) == Data("RIFF".utf8))
  }

  @Test func prepareMovesLeftoverActiveAudioToFailed() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending(path: "active"), withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: "active/leftover.wav"))
    await RecordingArchive(root: root, now: { start }).prepare()
    #expect(try files(root.appending(path: "active")).isEmpty)
    #expect(try files(root.appending(path: "failed")) == ["leftover.json", "leftover.wav"])
    let metadata = try JSONDecoder().decode(
      RecordingArchive.FailureMetadata.self,
      from: Data(contentsOf: root.appending(path: "failed/leftover.json")))
    #expect(metadata.reason == "interrupted")
  }

  @Test func preparePrunesFailedEntriesOlderThanSevenDays() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFailed("old", failedAt: start.addingTimeInterval(-8 * day), in: root)
    try writeFailed("recent", failedAt: start.addingTimeInterval(-6 * day), in: root)
    await RecordingArchive(root: root, now: { start }).prepare()
    #expect(try files(root.appending(path: "failed")) == ["recent.json", "recent.wav"])
  }

  @Test func pruneFallsBackToModificationDateWithoutMetadata() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let failed = root.appending(path: "failed")
    try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
    try Data().write(to: failed.appending(path: "bare.wav"))
    try FileManager.default.setAttributes(
      [.modificationDate: start.addingTimeInterval(-8 * day)],
      ofItemAtPath: failed.appending(path: "bare.wav").path)
    await RecordingArchive(root: root, now: { start }).prepare()
    #expect(try files(failed).isEmpty)
  }

  @Test func failWithoutKeepWritesNothing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecordingArchive(root: root, now: { start })
    await archive.prepare()
    await archive.fail(SessionID(raw: 7), .noSpeech)
    #expect(try files(root.appending(path: "failed")).isEmpty)
  }
}
