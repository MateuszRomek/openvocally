import Foundation

/// The local-models folder: where each model lives, whether it is complete, and the
/// cleanup of downloads that never finished.
public struct ModelFolder: Sendable {
  public let root: URL
  let manifests: @Sendable (HostedModel) -> ModelManifest

  public init(root: URL) {
    self.init(root: root) { $0.pinned }
  }

  init(root: URL, manifests: @escaping @Sendable (HostedModel) -> ModelManifest) {
    self.root = root
    self.manifests = manifests
  }

  public func manifest(of model: HostedModel) -> ModelManifest {
    manifests(model)
  }

  /// Keyed by bundle ID so Debug and Release keep separate models.
  public static func `default`(bundleIdentifier: String) -> ModelFolder {
    ModelFolder(
      root: URL.applicationSupportDirectory
        .appending(path: bundleIdentifier, directoryHint: .isDirectory)
        .appending(path: "local-models", directoryHint: .isDirectory))
  }

  public func location(of model: HostedModel) -> URL {
    root.appending(path: model.installPath, directoryHint: model.isSingleFile ? .notDirectory : .isDirectory)
  }

  /// Complete only when every pinned file is there at its pinned size. Hashing on every
  /// launch would read gigabytes, so the SHA-256 is checked once, before the install.
  public func isInstalled(_ model: HostedModel) -> Bool {
    let location = location(of: model)
    let manifest = manifest(of: model)
    return manifest.files.allSatisfy { file in
      let url = model.isSingleFile ? location : location.appending(path: manifest.localPath(for: file))
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
      return size == file.size
    }
  }

  /// The hidden folder a download fills before it is moved into place. It sits next to the
  /// final location, so the move is a rename on the same volume.
  func stagingFolder(for model: HostedModel, at date: Date) -> URL {
    let millis = Int64(date.timeIntervalSince1970 * 1000)
    return root.appending(path: model.id.engine.rawValue, directoryHint: .isDirectory)
      .appending(path: ".\(model.rawValue)-\(millis).download", directoryHint: .isDirectory)
  }

  public func delete(_ model: HostedModel) throws {
    try FileManager.default.removeItem(at: location(of: model))
  }

  static let staleAge: TimeInterval = 60 * 60

  /// Removes downloads left by a crash or a force quit once they are an hour old, so a
  /// download still running in another copy of the app is left alone.
  package func sweepStaleDownloads(now: Date = .now) {
    let manager = FileManager.default
    for engine in Set(ModelID.hosted.map(\.id.engine)) {
      let folder = root.appending(path: engine.rawValue, directoryHint: .isDirectory)
      guard
        let entries = try? manager.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
      else { continue }
      for entry in entries where entry.lastPathComponent.hasSuffix(".download") {
        let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        guard let modified, now.timeIntervalSince(modified) >= Self.staleAge else { continue }
        try? manager.removeItem(at: entry)
      }
    }
  }
}
