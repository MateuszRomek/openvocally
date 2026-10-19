import DictationCore
import Foundation
import Observation
import Storage
import Synchronization
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "app")

/// Where the app keeps its files: under the bundle id, so no other build or app
/// shares them.
enum AppData {
  static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.openvocally.app.debug"
  static let directory: URL = {
    #if DEBUG
      // -dataFolder <absolute path>: a scratch folder, so a harness never touches the real
      // history or recordings.
      if let path = UserDefaults.standard.string(forKey: "dataFolder"), path.hasPrefix("/") {
        return URL(filePath: path, directoryHint: .isDirectory)
      }
    #endif
    return URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
  }()
}

/// The transcript database and what depends on it being open: the screen cache, retention and
/// the pipeline's save. The only writer of the save target and of the cache resets.
@MainActor @Observable final class History {
  enum State {
    case opening
    case ready(AppDatabase)
    /// Dictation still works; history isn't saved until it opens.
    case failed
  }

  private(set) var state = State.opening
  @ObservationIgnored let cache = ScreenCache()

  var database: AppDatabase? {
    if case .ready(let database) = state { database } else { nil }
  }

  /// The database the pipeline saves to, read off the main actor. Set again by Try Again.
  @ObservationIgnored private let target = SaveTarget()
  @ObservationIgnored private var retention: Task<Void, Never>?

  /// Launch and Try Again. On success it warms the app icons, then stores the newest
  /// Transcripts page and only then starts retention, so the retention delete clears the
  /// stored page.
  @discardableResult func open() async -> AppDatabase? {
    state = .opening
    let opened = await Self.openFile()
    target.current = opened
    state = opened.map(State.ready) ?? .failed
    if let opened {
      Task { await Self.warmAppIcons(opened) }
      Task {
        await warmTranscripts(opened)
        applyRetention()
      }
    }
    return opened
  }

  /// Deletes transcripts past the retention now and then every 24 h. Settings calls it again
  /// when the retention changes.
  func applyRetention() {
    retention?.cancel()
    #if DEBUG
      if TranscriptsHarness.isRequested || TranscriptsHarness.seedRows != nil { return }
    #endif
    guard let database else { return }
    retention = Task { await Self.runRetention(database, cache: cache) }
  }

  func deleteAll() async {
    guard let database else { return }
    do {
      try await database.deleteAllTranscripts()
      cache.removeAll()
    } catch {
      logger.error("Deleting all transcripts failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// The pipeline's save. It reads the locked target and never hops to the main actor.
  @concurrent nonisolated func save(_ entry: DictationEntry) async {
    do {
      try await target.current?.save(entry)
    } catch {
      logger.error("Saving a transcript failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// Shutdown, after the hotkeys stop: retention gets 0.2 s, then the database closes.
  func close() async {
    retention?.cancel()
    if let retention { _ = await withDeadline(.seconds(0.2)) { await retention.value } }
    let database = target.current
    target.current = nil
    do {
      try database?.close()
    } catch {
      logger.error("Closing the database failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// Stores the newest Transcripts page, so the first open draws the list in its first frame like
  /// every later open, instead of a spinner until the observation's first page.
  private func warmTranscripts(_ database: AppDatabase) async {
    do {
      let page = try await database.transcriptPage(limit: TranscriptPaging.pageSize)
      cache.store(page, in: database)
    } catch {
      logger.error("Reading the newest transcripts failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// Resolves the icons of the apps dictated into before Home or Transcripts first draws them.
  private static func warmAppIcons(_ database: AppDatabase) async {
    do {
      AppIconCache.shared.warm(try await database.appBundleIDs())
    } catch {
      logger.error("Reading the app bundle ids failed: \(String(describing: error), privacy: .private)")
    }
  }

  @concurrent private nonisolated static func runRetention(_ database: AppDatabase, cache: ScreenCache) async
  {
    while !Task.isCancelled {
      if let cutoff = TranscriptRetention.saved.cutoff(now: .now) {
        do {
          let deleted = try await database.deleteTranscripts(olderThan: cutoff)
          logger.notice("Retention deleted \(deleted, privacy: .public) transcripts")
          if deleted > 0 { await cache.removeAll() }
        } catch {
          logger.error("Retention failed: \(String(describing: error), privacy: .private)")
        }
      }
      try? await Task.sleep(for: .seconds(86_400))
    }
  }

  @concurrent private nonisolated static func openFile() async -> AppDatabase? {
    do {
      #if DEBUG
        if let seeded = try await TranscriptsHarness.openSeededDatabase(in: AppData.directory) {
          return seeded
        }
      #endif
      return try AppDatabase.open(
        at: AppData.directory.appending(path: "openvocally.sqlite"),
        formerlyAt: AppData.directory.appending(path: "openvocaly.sqlite"))
    } catch {
      logger.error("Opening the database failed: \(String(describing: error), privacy: .private)")
      return nil
    }
  }
}

/// A database reference the pipeline reads off the main actor.
private final class SaveTarget: Sendable {
  private let lock = Mutex<AppDatabase?>(nil)

  var current: AppDatabase? {
    get { lock.withLock { $0 } }
    set { lock.withLock { $0 = newValue } }
  }
}
