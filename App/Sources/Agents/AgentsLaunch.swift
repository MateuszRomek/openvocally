#if FEATURE_AGENTS
  import Agents
  import AppKit
  import Storage
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "agents")

  /// Makes the agents service once the database is open. The one place that reads
  /// `-agentsScenario`.
  @MainActor enum AgentsLaunch {
    static func service(for database: AppDatabase?) async -> AgentsService? {
      guard let database else { return nil }
      let service = AgentsService(database: database)
      do {
        try await service.load()
      } catch {
        logger.error("Loading the projects failed: \(String(describing: error), privacy: .private)")
      }
      return service
    }

    #if DEBUG
      /// `-agentsScenario empty|projects|folder-missing -dataFolder <absolute path>`.
      /// Quits on an unknown name, so a mistyped shot row fails instead of showing `empty`.
      static var scenario: AgentsScenario? {
        guard let name = UserDefaults.standard.string(forKey: "agentsScenario") else { return nil }
        guard let scenario = AgentsScenario(rawValue: name) else {
          logger.fault("Unknown -agentsScenario \(name, privacy: .public)")
          exit(64)
        }
        return scenario
      }

      /// The file `scripts/agents/agents-shots.sh` waits for, written once the window shows the
      /// seeded projects.
      static var readyFile: URL { AppData.directory.appending(path: "agents-ready") }

      /// Seeds the scratch data folder. Refuses, and quits, without `-dataFolder`, so a scenario
      /// never writes into the real data.
      static func seededService(_ scenario: AgentsScenario, database: AppDatabase?) async -> AgentsService? {
        guard let path = UserDefaults.standard.string(forKey: "dataFolder"), path.hasPrefix("/") else {
          logger.fault("-agentsScenario needs -dataFolder <absolute path>")
          exit(64)
        }
        guard let database else {
          logger.fault("The scenario database did not open")
          exit(70)
        }
        do {
          return try await AgentsScenario.seed(
            scenario, database: database, dataFolder: AppData.directory,
            root: AppData.directory.appending(path: "agents-folders", directoryHint: .isDirectory))
        } catch {
          logger.fault("Seeding the agents scenario failed: \(String(describing: error), privacy: .private)")
          exit(70)
        }
      }

      /// The screen's first list, for `scripts/agents/agents-bench.sh --screen`: milliseconds from the
      /// screen's creation to the list drawn, and its row count.
      static var listShown: (ms: Double, rows: Int)?

      /// Gives the main window the default 900 x 670 size, so shots don't take the size the user
      /// last left it at, waits for the first list, then a frame, and writes the ready file.
      static func markReady() async {
        NSApplication.shared.windows.first { $0.isVisible && $0.canBecomeMain }?
          .setContentSize(NSSize(width: 900, height: 670))
        for _ in 0..<200 where listShown == nil { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(200))
        do {
          let shown = listShown.map { String(format: "ms=%.1f rows=%d\n", $0.ms, $0.rows) } ?? ""
          try Data("ready\n\(shown)".utf8).write(to: readyFile, options: .atomic)
        } catch {
          logger.error(
            "Writing the agents ready file failed: \(String(describing: error), privacy: .private)")
        }
      }
    #endif
  }
#endif
