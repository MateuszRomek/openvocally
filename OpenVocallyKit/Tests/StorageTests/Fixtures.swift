import Foundation
import Testing

@testable import DictationCore

func entry(
  _ text: String, session: UInt64 = 1, mode: RecordingMode = .toggle,
  pressedAt: HostTime = HostTime(ticks: 0),
  recording: Duration = .seconds(2),
  target: TargetApp? = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
) throws -> DictationEntry {
  DictationEntry(
    session: SessionID(raw: session), mode: mode, pressedAt: pressedAt, recordingDuration: recording,
    transcript: try #require(Transcript(text)), target: target)
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: "StorageTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
