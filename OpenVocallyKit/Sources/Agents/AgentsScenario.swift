#if FEATURE_AGENTS && DEBUG
  import AgentsCore
  import Foundation
  import Storage

  /// Debug data for `-agentsScenario <name>`. Seeds a scratch data folder through the service and
  /// the store, with real folders under `root`, so folder health is the real check.
  public enum AgentsScenario: String, Sendable, CaseIterable {
    /// No projects.
    case empty
    /// Four projects, one a subfolder and one renamed, with threads and conversations, one thread
    /// waiting on a permission request.
    case projects
    /// `projects`, then one project's folder deleted.
    case folderMissing = "folder-missing"
    /// 40 projects of 300 threads with 20 items each, for measuring the thread list at scale. Each
    /// project's eleventh-newest thread is waiting on you.
    case large

    public enum Refusal: Error {
      /// `root` is not inside the data folder, so seeding could write outside the scratch folder.
      case rootOutsideDataFolder
    }

    /// The name of the folder whose project `folderMissing` breaks.
    static let missingFolder = "notes-api"

    package static let largeProjects = 40
    package static let largeThreadsPerProject = 300
    package static let largeItemsPerThread = 20

    @MainActor public static func seed(
      _ scenario: Self, database: AppDatabase, dataFolder: URL, root: URL, now: Date = .now
    ) async throws -> AgentsService {
      // Compared as written: standardizing drops `/private` only from paths that exist.
      let data = dataFolder.pathComponents
      let inside = root.pathComponents
      guard inside.count > data.count, inside.starts(with: data), !inside.contains("..") else {
        throw Refusal.rootOutsideDataFolder
      }
      let service = AgentsService(database: database, clock: { now })
      guard scenario != .empty else {
        try await service.load()
        return service
      }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      func folder(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
      }
      func add(_ path: String) async throws -> Project.ID {
        guard case .added(let id) = try await service.addProject(at: try folder(path)) else {
          throw CocoaError(.fileWriteUnknown)
        }
        return id
      }
      if scenario == .large {
        var projects: [Project.ID] = []
        for index in 1...largeProjects { projects.append(try await add("project-\(index)")) }
        let waiting = try await database.seedAgentThreads(
          projects: projects, threads: largeThreadsPerProject, items: largeItemsPerThread, now: now)
        for thread in waiting { service.setWaiting(thread, true) }
        try await service.load()
        return service
      }
      let app = try await add("openvocally")
      let site = try await add("website")
      let docs = try await add("openvocally/docs")
      let api = try await add(missingFolder)
      try await service.rename(site, to: "Marketing Site")

      let minute: TimeInterval = 60
      let login = try await database.insertThread(
        NewThread(
          projectID: app, provider: .claude, title: "Fix the paste delay", createdAt: now - 50 * minute))
      try await database.appendItems(
        [
          NewConversationItem(
            seq: 1, createdAt: now - 50 * minute,
            content: .userMessage(text: "Find why the paste waits after release")),
          NewConversationItem(
            seq: 2, createdAt: now - 49 * minute,
            content: .toolStep(ToolStep(name: "Read", summary: "Read Paster.swift", succeeded: true))),
          NewConversationItem(
            seq: 3, createdAt: now - 48 * minute,
            content: .request(PermissionRequest(requestID: "req-1", tool: "Bash", summary: "make test"))),
        ], to: login)
      service.setWaiting(login, true)
      let icons = try await database.insertThread(
        NewThread(
          projectID: app, provider: .codex, title: "Update the menu bar icon",
          createdAt: now - 3 * 60 * minute))
      try await database.appendItems(
        [
          NewConversationItem(
            seq: 1, createdAt: now - 3 * 60 * minute,
            content: .userMessage(text: "Make the menu bar icon thinner")),
          NewConversationItem(
            seq: 2, createdAt: now - 3 * 60 * minute + minute,
            content: .assistantMessage(text: "Done. The icon now uses a 1.5 pt stroke.")),
        ], to: icons)
      let hero = try await database.insertThread(
        NewThread(
          projectID: site, provider: .claude, title: "Rewrite the hero copy",
          createdAt: now - 26 * 60 * minute))
      try await database.appendItems(
        [
          NewConversationItem(
            seq: 1, createdAt: now - 26 * 60 * minute, content: .userMessage(text: "Shorten the hero copy")),
          NewConversationItem(
            seq: 2, createdAt: now - 26 * 60 * minute + minute,
            content: .request(PermissionRequest(requestID: "req-2", tool: "Edit", summary: "index.html"))),
          NewConversationItem(
            seq: 3, createdAt: now - 26 * 60 * minute + 2 * minute,
            content: .outcome(RequestOutcome(requestID: "req-2", decision: .allowed))),
          NewConversationItem(
            seq: 4, createdAt: now - 26 * 60 * minute + 3 * minute,
            content: .assistantMessage(text: "The hero now reads in one line.")),
        ], to: hero)
      _ = try await database.insertThread(
        NewThread(
          projectID: docs, provider: .codex, title: "Proofread the latency doc",
          createdAt: now - 72 * 60 * minute))
      _ = try await database.insertThread(
        NewThread(
          projectID: api, provider: .claude, title: "Add rate limits", createdAt: now - 5 * 24 * 60 * minute))

      if scenario == .folderMissing {
        try FileManager.default.removeItem(
          at: root.appending(path: missingFolder, directoryHint: .isDirectory))
      }
      try await service.load()
      // Before the screen shows, so the Folder missing shot never catches the row unchecked.
      await service.refreshHealth()
      return service
    }
  }
#endif
