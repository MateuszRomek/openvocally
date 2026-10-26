#if FEATURE_AGENTS
  import AgentsCore
  import Foundation
  import Observation
  import Storage
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "agents")

  public enum AddProjectOutcome: Hashable, Sendable {
    case added(Project.ID)
    /// Already listed; adding it again changes nothing.
    case existing(Project.ID)
    /// It had been removed from the list. Listed again, its threads still archived.
    case restored(Project.ID)
    case rejected(ProjectPathRejection)
  }

  public enum LocateOutcome: Hashable, Sendable {
    case relocated
    case unchanged
    /// That folder is already another project. Nothing is written.
    case alreadyAProject(Project.ID)
    case rejected(ProjectPathRejection)
  }

  /// The agents seam: the Agents screen and the tests call only this. It is the only writer of the
  /// projects, so it reloads after its own writes instead of observing the table, and each method's
  /// result is in `projects` when it returns. Folder health follows, so a slow volume delays only
  /// its own row's health, never the list or an edit.
  @MainActor @Observable public final class AgentsService {
    /// Listed projects, in list order, with health.
    public private(set) var projects: [ProjectRow] = []
    /// The last load failed. The screen offers Try Again, which calls `load()`.
    public private(set) var loadFailed = false
    /// Threads waiting on a request from you. Live state: it comes from the session that asked,
    /// never from storage, because a request dies with its session.
    public private(set) var waiting: Set<AgentThread.ID> = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let resolver: ProjectPathResolver
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var healthCheck: Task<Void, Never>?

    public init(
      database: AppDatabase, resolver: ProjectPathResolver = .init(),
      clock: @escaping @Sendable () -> Date = { .now }
    ) {
      self.database = database
      self.resolver = resolver
      self.clock = clock
    }

    /// Reads the projects. Their health follows in the background, so a hung volume never holds
    /// back the list. The App calls it after init and from Try Again.
    public func load() async throws {
      do {
        try await reload()
        loadFailed = false
      } catch {
        loadFailed = true
        throw error
      }
    }

    public func addProject(at url: URL) async throws -> AddProjectOutcome {
      let path: ProjectPath
      switch await resolver.resolve(url) {
      case .failure(let rejection):
        logger.notice("Refused a project folder: \(String(describing: rejection), privacy: .public)")
        return .rejected(rejection)
      case .success(let resolved): path = resolved
      }
      let upsert = try await database.upsertProject(path, now: clock())
      try await reload()
      logger.info("Added a project at \(path.path, privacy: .private)")
      return switch upsert {
      case .inserted(let id): .added(id)
      case .alreadyListed(let id): .existing(id)
      case .restored(let id): .restored(id)
      }
    }

    /// A blank name shows the folder's name again.
    public func rename(_ id: Project.ID, to name: String) async throws {
      try await database.renameProject(id, to: ProjectName.normalized(name))
      try await reload()
    }

    /// Hides the project and archives its threads. Adding the folder again lists it again.
    public func remove(_ id: Project.ID) async throws {
      try await database.removeProject(id, now: clock())
      try await reload()
    }

    /// Points a project at another folder, for one whose folder is missing. Keeps the project's
    /// id, so its threads stay with it.
    public func locate(_ id: Project.ID, at url: URL) async throws -> LocateOutcome {
      let path: ProjectPath
      switch await resolver.resolve(url) {
      case .failure(let rejection): return .rejected(rejection)
      case .success(let resolved): path = resolved
      }
      let relocation = try await database.relocateProject(id, to: path)
      try await reload()
      return switch relocation {
      case .relocated: .relocated
      case .unchanged: .unchanged
      case .conflicts(let other): .alreadyAProject(other)
      }
    }

    /// Rechecks every folder. Assigns `projects` only when a health changed, so an unchanged check
    /// costs no redraw.
    public func refreshHealth() async {
      await withTaskGroup(of: (ProjectPath, FolderHealth).self) { group in
        for path in Set(projects.map(\.project.path)) {
          group.addTask { (path, await FolderHealthCheck.health(of: path)) }
        }
        // Each folder's answer lands as it comes, so a hung volume holds back only its own row.
        for await (path, health) in group where !Task.isCancelled {
          let rows = projects.map {
            $0.project.path == path ? ProjectRow(project: $0.project, health: health) : $0
          }
          if rows != projects { projects = rows }
        }
      }
    }

    /// How many of a project's newest threads the list shows before "Show more". The `large`
    /// scenario's 40 projects draw 240 rows with their waiting threads, which LB-11 measures.
    package static let threadsPerProject = 5
    /// How many more each "Show more" adds.
    public static let threadsPerShowMore = 25

    /// The thread list by project. `shown` holds the projects whose "Show more" the user pressed and
    /// how many threads each now shows. A thread that needs you, and `keeping`, are always in it,
    /// past any limit, so the open thread stays listed while newer ones push it past its project's.
    public func threads(
      shown: [Project.ID: Int] = [:], keeping: AgentThread.ID? = nil
    ) -> some AsyncSequence<[Project.ID: ThreadGroup], any Error> {
      database.threadGroups(
        shown: shown, perProject: Self.threadsPerProject, always: waiting.union(keeping.map { [$0] } ?? []))
    }

    public func conversation(_ thread: AgentThread.ID) -> some AsyncSequence<[ConversationItem], any Error> {
      database.conversation(thread)
    }

    /// The session engine's entry point for a request asked or answered; the Debug scenarios call
    /// it too.
    package func setWaiting(_ thread: AgentThread.ID, _ isWaiting: Bool) {
      if isWaiting { waiting.insert(thread) } else { waiting.remove(thread) }
    }

    package func draft() async throws -> StartDraft? {
      try await database.draft()
    }

    /// A draft with no text clears it.
    package func saveDraft(_ draft: StartDraft) async throws {
      try await database.saveDraft(draft, now: clock())
    }

    package func clearDraft() async throws {
      try await database.clearDraft()
    }

    /// Lists the projects at once, each with its last known health, and checks the folders after.
    /// A new path's folder was just resolved, so it starts available.
    private func reload() async throws {
      let listed = try await database.listedProjects()
      let known = Dictionary(
        projects.map { ($0.project.path, $0.health) }, uniquingKeysWith: { first, _ in first })
      let rows = listed.map { ProjectRow(project: $0, health: known[$0.path] ?? .available) }
      if rows != projects { projects = rows }
      healthCheck?.cancel()
      healthCheck = Task { await refreshHealth() }
    }
  }
#endif
