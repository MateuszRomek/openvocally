#if DEBUG
  import AppKit
  import Darwin
  import DictationCore
  import Observation
  import QuartzCore
  import Storage
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts-harness")

  extension TranscriptsHarness {
    nonisolated static func openSeededDatabase(in directory: URL) async throws -> AppDatabase? {
      guard let rows = seedRows else { return nil }
      let database = try AppDatabase.open(at: directory.appending(path: "seed-\(rows).sqlite"))
      let start = ContinuousClock.now
      try await database.seedTranscripts(count: rows)
      logger.notice(
        "Seed database with \(rows, privacy: .public) rows ready in \(ContinuousClock.now - start, privacy: .public)"
      )
      return database
    }

    /// Checks that the seed holds exactly its seeded rows before any scenario runs. Without
    /// `-seedTranscripts` the harness would save its dictations into the real Debug database.
    static func seedIntact(_ database: AppDatabase?) async -> Bool {
      guard let seeded = seedRows else { return fail("-transcriptsHarness needs -seedTranscripts") }
      guard let database else { return fail("seed database did not open") }
      do {
        let rows = try await database.transcriptCount()
        record("seed rows at start", Double(rows))
        guard rows == seeded else { return fail("seed has \(rows) rows at start, not \(seeded)") }
        return true
      } catch {
        logger.error("Counting the seed rows failed: \(String(describing: error), privacy: .public)")
        return fail("count seed rows")
      }
    }

    /// Deletes every dictation the harness saved once the saves in flight land, and checks that
    /// the seed is back to exactly its seeded rows, so runs never pile rows into it.
    static func removeSaves(_ database: AppDatabase?) async -> Bool {
      guard let database, let seeded = seedRows else { return true }
      for save in saves { await save.value }
      saves = []
      do {
        let left = try await database.deleteSessions(targetAppName: appName)
        record("seed rows after cleanup", Double(left))
        guard left == seeded else { return fail("seed has \(left) rows, not \(seeded)") }
        return true
      } catch {
        logger.error(
          "Removing the synthetic dictations failed: \(String(describing: error), privacy: .public)")
        return fail("remove synthetic dictations")
      }
    }

    static func save(_ database: AppDatabase) {
      savedCount += 1
      let words = (0..<40).map { ["harness", "synthetic", "dictation", "number", "\(savedCount)"][$0 % 5] }
      guard let transcript = Transcript(words.joined(separator: " ")) else { return }
      let entry = DictationEntry(
        session: .synthetic(UInt64(savedCount)), mode: .pushToTalk, pressedAt: .now(),
        recordingDuration: .seconds(5), transcript: transcript,
        target: TargetApp(name: appName, bundleIdentifier: nil))
      saves.append(
        Task {
          do {
            try await database.save(entry)
          } catch {
            logger.error("Synthetic save failed: \(String(describing: error), privacy: .public)")
          }
        })
    }
  }
#endif
