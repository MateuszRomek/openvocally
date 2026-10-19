import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import Models

/// Small stand-in models: every file's bytes are known, so the manifests can pin real hashes.
public enum Fixture {
  public static let contents: [String: Data] = [
    "folder/a.bin": Data("alpha".utf8),
    "folder/b.json": Data("{\"b\":1}".utf8),
    "single.bin": Data("whisper".utf8),
  ]

  public static func file(_ path: String, contents data: Data? = nil) -> ModelFile {
    let data = data ?? contents[path] ?? Data()
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ModelFile(path: path, size: Int64(data.count), sha256: digest)
  }

  public static func manifest(_ model: ModelID) -> ModelManifest {
    let files =
      model.isSingleFile ? [file("single.bin")] : [file("folder/a.bin"), file("folder/b.json")]
    return ModelManifest(repository: "test/\(model.rawValue)", revision: "abc", localPrefix: "", files: files)
  }

  public static func folder() -> ModelFolder {
    ModelFolder(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) {
      manifest($0)
    }
  }

  /// Writes a model straight into place, as a finished download leaves it.
  public static func install(_ model: ModelID, in folder: ModelFolder) throws {
    let location = folder.location(of: model)
    for file in manifest(model).files {
      let url = model.isSingleFile ? location : location.appending(path: file.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try #require(contents[file.path]).write(to: url)
    }
  }
}

/// Serves `Fixture.contents` by the URL's last path components, with optional overrides.
public final class FakeFetcher: ModelFetching {
  private let state = Mutex<(fetched: [String], gate: CheckedContinuation<Void, Never>?, released: Bool)>(
    ([], nil, false))
  public let overrides: [String: Data]
  public let failure: DownloadError?
  public let waits: Bool

  public init(overrides: [String: Data] = [:], failure: DownloadError? = nil, waits: Bool = false) {
    self.overrides = overrides
    self.failure = failure
    self.waits = waits
  }

  public var fetched: [String] { state.withLock { $0.fetched } }

  public func release() {
    let gate = state.withLock { state in
      defer { (state.gate, state.released) = (nil, true) }
      return state.gate
    }
    gate?.resume()
  }

  public func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void)
    async throws(DownloadError)
  {
    let path = Fixture.contents.keys.first { url.path().hasSuffix("/" + $0) } ?? url.lastPathComponent
    state.withLock { $0.fetched.append(path) }
    if waits {
      await withCheckedContinuation { continuation in
        let released = state.withLock { state in
          if !state.released { state.gate = continuation }
          return state.released
        }
        if released { continuation.resume() }
      }
    }
    if Task.isCancelled { throw .cancelled }
    if let failure { throw failure }
    let data = overrides[path] ?? Fixture.contents[path] ?? Data()
    progress(Int64(data.count))
    do {
      try data.write(to: destination)
    } catch {
      throw .fileSystem
    }
  }
}
