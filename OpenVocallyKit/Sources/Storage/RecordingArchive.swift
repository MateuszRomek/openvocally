import DictationCore
import Foundation
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "storage")

/// Audio of in-flight recordings. `active/` holds audio waiting on its transcript;
/// `failed/` keeps audio whose dictation failed, for 7 days. An actor so file moves for one
/// session never interleave, and the work stays off the main actor.
public actor RecordingArchive {
  static let retention: TimeInterval = 7 * 24 * 60 * 60
  static let sampleRate = 16_000

  struct FailureMetadata: Codable, Equatable {
    var failedAt: Int64
    var reason: String
    var startedAt: Int64?
    var sampleRate: Int

    init(failedAt: Int64, reason: String, startedAt: Int64? = nil, sampleRate: Int) {
      self.failedAt = failedAt
      self.reason = reason
      self.startedAt = startedAt
      self.sampleRate = sampleRate
    }
  }

  private let active: URL
  private let failed: URL
  private let now: @Sendable () -> Date
  /// Session ids restart at 1 each launch, so files are named by a UUID instead.
  private var files: [SessionID: UUID] = [:]
  private let fileManager = FileManager()

  public init(root: URL, now: @escaping @Sendable () -> Date = Date.init) {
    active = root.appending(path: "active", directoryHint: .isDirectory)
    failed = root.appending(path: "failed", directoryHint: .isDirectory)
    self.now = now
  }

  public nonisolated var sink: RecordingSink {
    RecordingSink(
      keep: { await self.keep($0, $1) },
      discard: { await self.discard($0) },
      fail: { await self.fail($0, $1) })
  }

  /// Run at launch: audio left in `active/` belonged to a run that never finished. Each file is
  /// handled on its own, so one stuck file can't stop the rest from moving or expiring.
  public func prepare() {
    do {
      try fileManager.createDirectory(at: active, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: failed, withIntermediateDirectories: true)
    } catch {
      logger.error("Creating the recording folders failed: \(String(describing: error), privacy: .private)")
      return
    }
    for audio in contents(of: active) where audio.pathExtension == "wav" {
      do {
        try moveToFailed(audio, id: audio.deletingPathExtension().lastPathComponent, reason: "interrupted")
      } catch {
        logger.error("Archiving interrupted audio failed: \(String(describing: error), privacy: .private)")
      }
    }
    pruneFailed()
  }

  public func keep(_ session: SessionID, _ samples: [Float]) {
    let id = UUID()
    do {
      try fileManager.createDirectory(at: active, withIntermediateDirectories: true)
      try Self.wav(samples).write(to: active.appending(path: "\(id.uuidString).wav"), options: .atomic)
      files[session] = id
    } catch {
      logger.error(
        "Keeping audio for \(session, privacy: .public) failed: \(String(describing: error), privacy: .private)"
      )
    }
  }

  public func discard(_ session: SessionID) {
    guard let id = files.removeValue(forKey: session) else { return }
    do {
      try fileManager.removeItem(at: active.appending(path: "\(id.uuidString).wav"))
    } catch {
      logger.error(
        "Discarding audio for \(session, privacy: .public) failed: \(String(describing: error), privacy: .private)"
      )
    }
  }

  public func fail(_ session: SessionID, _ reason: DictationFailureReason) {
    guard let id = files.removeValue(forKey: session) else { return }
    do {
      try fileManager.createDirectory(at: failed, withIntermediateDirectories: true)
      try moveToFailed(
        active.appending(path: "\(id.uuidString).wav"), id: id.uuidString, reason: reason.storedName)
    } catch {
      logger.error(
        "Archiving failed audio for \(session, privacy: .public) failed: \(String(describing: error), privacy: .private)"
      )
    }
  }

  private func moveToFailed(_ audio: URL, id: String, reason: String) throws {
    try fileManager.moveItem(at: audio, to: failed.appending(path: "\(id).wav"))
    let metadata = FailureMetadata(
      failedAt: unixMilliseconds(now()), reason: reason, startedAt: nil, sampleRate: Self.sampleRate)
    try JSONEncoder().encode(metadata).write(to: failed.appending(path: "\(id).json"), options: .atomic)
  }

  private func pruneFailed() {
    let entries = Dictionary(grouping: contents(of: failed)) { $0.deletingPathExtension().lastPathComponent }
    let cutoff = now().addingTimeInterval(-Self.retention)
    for (_, urls) in entries {
      guard let failedAt = failedAt(urls), failedAt < cutoff else { continue }
      for url in urls {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          logger.error("Deleting expired audio failed: \(String(describing: error), privacy: .private)")
        }
      }
    }
  }

  /// From the metadata, falling back to the audio file's modification date.
  private func failedAt(_ urls: [URL]) -> Date? {
    if let json = urls.first(where: { $0.pathExtension == "json" }),
      let data = try? Data(contentsOf: json),
      let metadata = try? JSONDecoder().decode(FailureMetadata.self, from: data)
    {
      return Date(timeIntervalSince1970: Double(metadata.failedAt) / 1000)
    }
    let file = urls.first { $0.pathExtension == "wav" } ?? urls.first
    return file.flatMap {
      try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
  }

  private func contents(of folder: URL) -> [URL] {
    do {
      return try fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
    } catch {
      logger.error("Listing recordings failed: \(String(describing: error), privacy: .private)")
      return []
    }
  }

  /// 16 kHz mono 32-bit float WAV (format tag 3). Written by hand: it is a 44-byte header and
  /// keeps the write a single atomic `Data` write.
  static func wav(_ samples: [Float]) -> Data {
    let dataBytes = UInt32(samples.count * 4)
    var data = Data(capacity: 44 + Int(dataBytes))
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(36 + dataBytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(3))
    append(UInt16(1))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 4))
    append(UInt16(4))
    append(UInt16(32))
    data.append(contentsOf: Array("data".utf8))
    append(dataBytes)
    for sample in samples { append(sample.bitPattern) }
    return data
  }
}

extension DictationFailureReason {
  /// Stable: written to failure metadata on disk.
  var storedName: String {
    switch self {
    case .microphonePermissionDenied: "microphonePermissionDenied"
    case .captureError(let failure):
      switch failure {
      case .noInputDevice: "captureError.noInputDevice"
      case .startTimedOut: "captureError.startTimedOut"
      case .stopTimedOut: "captureError.stopTimedOut"
      case .deviceLost: "captureError.deviceLost"
      case .captureFailed: "captureError.engineFailed"
      }
    case .aborted: "aborted"
    case .transcriptionError: "transcriptionError"
    case .noSpeech: "noSpeech"
    case .modelNotInstalled: "modelNotInstalled"
    case .pasteNotSupported: "pasteNotSupported"
    case .pastePermissionDenied: "pastePermissionDenied"
    case .pasteRuntimeError: "pasteRuntimeError"
    case .nothingToPaste: "nothingToPaste"
    case .manualPasteExpired: "manualPasteExpired"
    }
  }
}
