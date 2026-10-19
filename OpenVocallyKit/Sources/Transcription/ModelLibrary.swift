import Foundation
import Models
import Observation

/// What the Models screen shows and does: installed models, the active one, the download in
/// progress and the last failure per model.
@MainActor @Observable public final class ModelLibrary {
  public struct Download: Equatable, Sendable {
    public let model: ModelID
    public var progress: DownloadProgress

    /// 0 to 1, or nil while verifying.
    public var fraction: Double? {
      guard case .downloading(let received, let total) = progress, total > 0 else { return nil }
      return Double(received) / Double(total)
    }
  }

  public enum DeleteError: Error, Equatable {
    /// The active model can go only when another installed model can take over.
    case noReplacement
    case downloading
    case fileSystem
  }

  public private(set) var installed: Set<ModelID> = []
  public private(set) var active: ModelID
  public private(set) var download: Download?
  public private(set) var failures: [ModelID: DownloadError] = [:]
  public private(set) var runtime: RuntimeState = .loading

  @ObservationIgnored private let folder: ModelFolder
  @ObservationIgnored private let downloader: ModelDownloader
  @ObservationIgnored private let transcription: TranscriptionRuntime
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  /// The runtime's state stream outlives the library, so its reader stops only when cancelled.
  @ObservationIgnored private var stateTask: Task<Void, Never>?

  static let activeKey = "transcription.modelID"

  public init(
    folder: ModelFolder, downloader: ModelDownloader, runtime: TranscriptionRuntime,
    defaults: UserDefaults = .standard
  ) {
    self.folder = folder
    self.downloader = downloader
    self.transcription = runtime
    self.defaults = defaults
    active = defaults.string(forKey: Self.activeKey).flatMap(ModelID.init) ?? .preferred
  }

  isolated deinit {
    stateTask?.cancel()
  }

  /// Sweeps old downloads, reads what is installed and starts loading the active model.
  public func start() async {
    guard !started else { return }
    started = true
    let transcription = transcription
    stateTask = Task { [weak self] in
      for await state in transcription.states { self?.runtime = state }
    }
    installed = await Self.sweepAndScan(folder)
    if !installed.contains(active), let replacement = replacement(for: active) {
      choose(replacement)
    }
    await transcription.activate(installed.contains(active) ? active : nil)
  }

  public func location(of model: ModelID) -> URL {
    folder.location(of: model)
  }

  func canSelect(_ model: ModelID) -> Bool {
    installed.contains(model)
  }

  public func select(_ model: ModelID) {
    guard canSelect(model), model != active else { return }
    choose(model)
    let transcription = transcription
    Task { await transcription.activate(model) }
  }

  /// The model that takes over when `model` is deleted: the preferred one first, then the
  /// catalog order.
  public func replacement(for model: ModelID) -> ModelID? {
    ([ModelID.preferred] + ModelID.allCases).first { $0 != model && canSelect($0) }
  }

  public func startDownload(_ model: ModelID) {
    guard !installed.contains(model) else { return }
    download(model, replacing: false)
  }

  private func download(_ model: ModelID, replacing: Bool) {
    guard download == nil else { return }
    failures[model] = nil
    download = Download(
      model: model, progress: .downloading(received: 0, total: folder.manifest(model).totalBytes))
    let downloader = downloader
    let (updates, sink) = AsyncStream.makeStream(
      of: DownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
    Task {
      for await progress in updates { report(progress, for: model) }
    }
    downloadTask = Task {
      var failure: DownloadError?
      do throws(DownloadError) {
        try await downloader.install(model, replacing: replacing) { sink.yield($0) }
      } catch {
        failure = error
      }
      sink.finish()
      await finishDownload(model, error: failure)
    }
  }

  /// A model that is on disk but won't load can't be deleted when it is the only one,
  /// so this downloads it again. The old files stay until the new ones pass verification.
  public func redownload(_ model: ModelID) {
    guard installed.contains(model) else { return }
    download(model, replacing: true)
  }

  public func cancelDownload() {
    downloadTask?.cancel()
  }

  public func delete(_ model: ModelID) async throws(DeleteError) {
    guard download?.model != model else { throw .downloading }
    if model == active {
      guard let replacement = replacement(for: model) else { throw .noReplacement }
      select(replacement)
    }
    let deleted = await Self.delete(model, in: folder)
    installed = await Self.scan(folder)
    guard deleted else { throw .fileSystem }
  }

  private func choose(_ model: ModelID) {
    active = model
    defaults.set(model.rawValue, forKey: Self.activeKey)
  }

  /// Progress arrives for every network read, so only a whole-percent change redraws.
  private func report(_ progress: DownloadProgress, for model: ModelID) {
    guard var download, download.model == model else { return }
    let before = download.fraction.map { Int($0 * 100) }
    download.progress = progress
    guard download.fraction.map({ Int($0 * 100) }) != before || progress == .verifying else { return }
    self.download = download
  }

  private func finishDownload(_ model: ModelID, error: DownloadError?) async {
    download = nil
    downloadTask = nil
    if let error, error != .cancelled { failures[model] = error }
    let wasMissing = !installed.contains(active)
    installed = await Self.scan(folder)
    guard error == nil, installed.contains(model), model == active || wasMissing else { return }
    choose(model)
    await transcription.activate(model)
  }

  @concurrent private nonisolated static func sweepAndScan(_ folder: ModelFolder) async -> Set<ModelID> {
    folder.sweepStaleDownloads()
    return folder.installedModels()
  }

  @concurrent private nonisolated static func scan(_ folder: ModelFolder) async -> Set<ModelID> {
    folder.installedModels()
  }

  @concurrent private nonisolated static func delete(_ model: ModelID, in folder: ModelFolder) async -> Bool {
    (try? folder.delete(model)) != nil
  }
}
