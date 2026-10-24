import CryptoKit
import Foundation
import Synchronization
import os

public enum DownloadError: Error, Equatable, Sendable {
  /// Another model is downloading.
  case busy
  case cancelled
  case offline
  case server(status: Int)
  /// A file arrived with a different size or SHA-256 than the manifest pins.
  case corrupted
  case diskFull
  case fileSystem
}

public enum DownloadProgress: Sendable, Equatable {
  case downloading(received: Int64, total: Int64)
  /// Downloading, with no size yet to measure the download against.
  case indeterminate
  case verifying

  /// 0 to 1, or nil while the size is unknown or the files are verifying.
  public var fraction: Double? {
    guard case .downloading(let received, let total) = self, total > 0 else { return nil }
    return Double(received) / Double(total)
  }
}

/// Fetches one URL to a file. Tests swap in a fake; the app uses `URLSessionFetcher`.
public protocol ModelFetching: Sendable {
  /// `progress` reports the bytes of this file received so far.
  func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void)
    async throws(DownloadError)
}

private let logger = Logger(subsystem: "com.openvocally.app", category: "models")

/// Downloads a model into a hidden folder, checks every file's size and SHA-256, then moves it
/// into place, so a model on disk is either complete or absent.
public actor ModelDownloader {
  private let folder: ModelFolder
  private let fetcher: any ModelFetching
  private let now: @Sendable () -> Date
  private var active: HostedModel?

  public init(folder: ModelFolder, fetcher: any ModelFetching, now: @escaping @Sendable () -> Date = { .now })
  {
    self.folder = folder
    self.fetcher = fetcher
    self.now = now
  }

  /// One download at a time across every engine. Cancel by cancelling the calling task.
  /// `replacing` downloads a model that is already installed, such as one that won't load, and
  /// swaps it in only after the new files pass verification.
  package func install(
    _ model: HostedModel, replacing: Bool = false,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(DownloadError) {
    do {
      try await fetchAndInstall(model, replacing: replacing, progress: progress)
    } catch {
      logger.notice(
        "Model download ended: \(model.rawValue, privacy: .public), \(String(describing: error), privacy: .public)"
      )
      throw error
    }
  }

  private func fetchAndInstall(
    _ model: HostedModel, replacing: Bool, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(DownloadError) {
    guard active == nil else { throw .busy }
    active = model
    defer { active = nil }
    guard replacing || !folder.isInstalled(model) else { return }

    let staging = folder.stagingFolder(for: model, at: now())
    defer { try? FileManager.default.removeItem(at: staging) }
    let manifest = folder.manifest(of: model)
    let total = manifest.totalBytes
    logger.notice(
      "Model download started: \(model.rawValue, privacy: .public), \(total, privacy: .public) bytes, replacing: \(replacing, privacy: .public)"
    )
    var finished: Int64 = 0
    progress(.downloading(received: 0, total: total))
    for file in manifest.files {
      guard !Task.isCancelled else { throw .cancelled }
      let destination = staging.appending(path: manifest.localPath(for: file))
      try Self.makeFolder(destination.deletingLastPathComponent())
      let before = finished
      try await fetcher.fetch(manifest.remoteURL(for: file), to: destination) { received in
        progress(.downloading(received: before + min(received, file.size), total: total))
      }
      finished += file.size
    }

    guard !Task.isCancelled else { throw .cancelled }
    progress(.verifying)
    for file in manifest.files {
      let url = staging.appending(path: manifest.localPath(for: file))
      guard try await Self.matches(url, file) else {
        logger.error(
          "\(model.rawValue, privacy: .public) failed verification at \(file.path, privacy: .public)")
        throw .corrupted
      }
      guard !Task.isCancelled else { throw .cancelled }
    }
    try moveIntoPlace(
      model, from: model.isSingleFile ? staging.appending(path: manifest.files[0].path) : staging)
    logger.notice("Model installed: \(model.rawValue, privacy: .public)")
  }

  private func moveIntoPlace(_ model: HostedModel, from source: URL) throws(DownloadError) {
    let manager = FileManager.default
    let location = folder.location(of: model)
    do {
      try Self.makeFolder(location.deletingLastPathComponent())
      if manager.fileExists(atPath: location.path) { try manager.removeItem(at: location) }
      try manager.moveItem(at: source, to: location)
    } catch {
      throw Self.fileError(error)
    }
  }

  private static func makeFolder(_ url: URL) throws(DownloadError) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw fileError(error)
    }
  }

  static func fileError(_ error: any Error) -> DownloadError {
    if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace { return .diskFull }
    if let error = error as? POSIXError, error.code == .ENOSPC { return .diskFull }
    logger.error("Model file operation failed: \(error.localizedDescription, privacy: .public)")
    return .fileSystem
  }

  /// Hashes in 4 MB reads off the actor, so a 4 GB model doesn't hold the downloader.
  @concurrent private static func matches(_ url: URL, _ file: ModelFile) async throws(DownloadError) -> Bool {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hash = SHA256()
      var size: Int64 = 0
      while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        guard !Task.isCancelled else { throw DownloadError.cancelled }
        hash.update(data: chunk)
        size += Int64(chunk.count)
      }
      let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
      return size == file.size && digest == file.sha256
    } catch let error as DownloadError {
      throw error
    } catch {
      throw fileError(error)
    }
  }
}

/// Downloads with a session that keeps nothing on disk, so a 4 GB response never lands in the
/// URL cache.
public struct URLSessionFetcher: ModelFetching {
  private static let session = URLSession(configuration: .ephemeral)

  public init() {}

  public func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void)
    async throws(DownloadError)
  {
    // The delegate of the async download(from:delegate:) never receives didWriteData (measured
    // 2026-10-15: 0 calls over a 23.6 MB file), so progress is read off the task instead.
    let running = Mutex<URLSessionDownloadTask?>(nil)
    let poller = Task {
      while !Task.isCancelled {
        if let task = running.withLock({ $0 }) { progress(task.countOfBytesReceived) }
        try? await Task.sleep(for: Self.progressInterval)
      }
    }
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<Result<Void, DownloadError>, Never>) in
        let task = Self.session.downloadTask(with: url) { location, response, error in
          continuation.resume(returning: Self.complete(location, response, error, to: destination))
        }
        running.withLock { $0 = task }
        task.resume()
        if Task.isCancelled { task.cancel() }
      }
    } onCancel: {
      running.withLock { $0?.cancel() }
    }
    poller.cancel()
    // A report still in flight would land after the caller's `.verifying`.
    await poller.value
    // The completion handler runs outside the task, so a cancel that races a network error
    // is resolved here.
    if Task.isCancelled { throw .cancelled }
    try result.get()
  }

  static let progressInterval: Duration = .milliseconds(100)

  /// Runs in the task's completion handler, while the downloaded file still exists.
  private static func complete(
    _ location: URL?, _ response: URLResponse?, _ error: (any Error)?, to destination: URL
  )
    -> Result<Void, DownloadError>
  {
    if let error { return .failure(networkError(error)) }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      return .failure(.server(status: http.statusCode))
    }
    guard let location else { return .failure(.fileSystem) }
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      return .success(())
    } catch {
      return .failure(ModelDownloader.fileError(error))
    }
  }

  static func networkError(_ error: any Error) -> DownloadError {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    guard let error = error as? URLError else { return ModelDownloader.fileError(error) }
    switch error.code {
    case .cancelled: return .cancelled
    case .cannotWriteToFile: return .fileSystem
    default:
      logger.error("Model download failed: \(error.code.rawValue, privacy: .public)")
      return .offline
    }
  }
}
