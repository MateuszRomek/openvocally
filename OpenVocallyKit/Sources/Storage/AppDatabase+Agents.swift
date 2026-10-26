#if FEATURE_AGENTS
  import AgentsCore
  import Foundation
  import GRDB

  /// Where an add landed.
  package enum ProjectUpsert: Hashable, Sendable {
    case inserted(Project.ID)
    case alreadyListed(Project.ID)
    /// It had been removed from the list and is listed again. Its threads stay archived.
    case restored(Project.ID)

    package var id: Project.ID {
      switch self {
      case .inserted(let id), .alreadyListed(let id), .restored(let id): id
      }
    }
  }

  package enum ProjectRelocation: Hashable, Sendable {
    case relocated
    case unchanged
    case conflicts(with: Project.ID)
  }

  /// All `package`: only `AgentsService` and the package's tests call these, so the dedupe and
  /// worktree rules have one owner and the App cannot write around them.
  extension AppDatabase {
    /// The Agents tables, registered by `migrator` with `registerUnshippedMigration` until Agents
    /// ships, so this stays editable until then.
    static let agentsSchema = """
      CREATE TABLE agent_projects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        custom_name TEXT,
        added_at INTEGER NOT NULL,
        setup_command TEXT,
        waits_for_setup INTEGER NOT NULL DEFAULT 1 CHECK (waits_for_setup IN (0, 1)),
        removed_at INTEGER
      );
      CREATE TABLE agent_threads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL REFERENCES agent_projects(id) ON DELETE CASCADE,
        provider TEXT NOT NULL,
        provider_session_id TEXT,
        worktree_path TEXT,
        title TEXT NOT NULL,
        title_renamed INTEGER NOT NULL DEFAULT 0 CHECK (title_renamed IN (0, 1)),
        created_at INTEGER NOT NULL,
        last_activity_at INTEGER NOT NULL,
        archived_at INTEGER,
        permission_mode TEXT NOT NULL,
        model TEXT,
        reasoning TEXT,
        UNIQUE(provider, provider_session_id)
      );
      CREATE INDEX agent_threads_project_activity
        ON agent_threads(project_id, archived_at, last_activity_at);
      CREATE TABLE agent_thread_allow_rules (
        thread_id INTEGER NOT NULL REFERENCES agent_threads(id) ON DELETE CASCADE,
        rule TEXT NOT NULL,
        PRIMARY KEY (thread_id, rule)
      ) WITHOUT ROWID;
      CREATE TABLE agent_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        thread_id INTEGER NOT NULL REFERENCES agent_threads(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        kind TEXT NOT NULL,
        request_id TEXT,
        created_at INTEGER NOT NULL,
        body_json TEXT NOT NULL,
        UNIQUE(thread_id, seq)
      );
      CREATE TABLE agent_draft (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        project_id INTEGER REFERENCES agent_projects(id) ON DELETE SET NULL,
        text TEXT NOT NULL,
        provider TEXT,
        permission_mode TEXT,
        model TEXT,
        reasoning TEXT,
        updated_at INTEGER NOT NULL
      );
      """

    /// Listed projects, the newest thread start first; a project without threads sorts by when it
    /// was added. The order is derived from the threads, so nothing has to keep a copy in sync.
    package func listedProjects() async throws -> [Project] {
      try await writer.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT p.id, p.path, p.custom_name, p.added_at, p.setup_command, p.waits_for_setup,
              (SELECT MAX(t.created_at) FROM agent_threads t WHERE t.project_id = p.id) AS last_started
            FROM agent_projects p
            WHERE p.removed_at IS NULL
            ORDER BY COALESCE(last_started, p.added_at) DESC, p.id DESC
            """
        ).map { row in
          let lastStarted: Int64? = row[6]
          return Project(
            id: Project.ID(row[0]), path: ProjectPath(trusted: row[1]), customName: row[2],
            addedAt: date(unixMilliseconds: row[3]),
            lastThreadStartedAt: lastStarted.map(date(unixMilliseconds:)),
            setupCommand: row[4], waitsForSetup: row[5])
        }
      }
    }

    /// One transaction, so two adds of one folder cannot both insert. Running it twice returns
    /// `.alreadyListed` the second time.
    package func upsertProject(_ path: ProjectPath, now: Date) async throws -> ProjectUpsert {
      try await writer.write { db in
        if let row = try Row.fetchOne(
          db, sql: "SELECT id, removed_at FROM agent_projects WHERE path = ?", arguments: [path.path])
        {
          let id = Project.ID(row[0])
          let removedAt: Int64? = row[1]
          guard removedAt != nil else { return .alreadyListed(id) }
          try db.execute(
            sql: "UPDATE agent_projects SET removed_at = NULL WHERE id = ?", arguments: [id.rawValue])
          return .restored(id)
        }
        try db.execute(
          sql: "INSERT INTO agent_projects (path, added_at) VALUES (?, ?)",
          arguments: [path.path, unixMilliseconds(now)])
        return .inserted(Project.ID(db.lastInsertedRowID))
      }
    }

    /// Nil clears the custom name.
    package func renameProject(_ id: Project.ID, to customName: String?) async throws {
      try await writer.write { db in
        try db.execute(
          sql: "UPDATE agent_projects SET custom_name = ? WHERE id = ?", arguments: [customName, id.rawValue])
      }
    }

    /// Hides the project and archives its threads. Running it twice keeps the first times.
    package func removeProject(_ id: Project.ID, now: Date) async throws {
      let nowMs = unixMilliseconds(now)
      try await writer.write { db in
        try db.execute(
          sql: "UPDATE agent_projects SET removed_at = COALESCE(removed_at, ?) WHERE id = ?",
          arguments: [nowMs, id.rawValue])
        try db.execute(
          sql: "UPDATE agent_threads SET archived_at = COALESCE(archived_at, ?) WHERE project_id = ?",
          arguments: [nowMs, id.rawValue])
      }
    }

    /// Keeps the project's id, so its threads stay with it. Another row with that path wins.
    package func relocateProject(_ id: Project.ID, to path: ProjectPath) async throws -> ProjectRelocation {
      try await writer.write { db in
        if let other = try Int64.fetchOne(
          db, sql: "SELECT id FROM agent_projects WHERE path = ?", arguments: [path.path])
        {
          return other == id.rawValue ? .unchanged : .conflicts(with: Project.ID(other))
        }
        try db.execute(
          sql: "UPDATE agent_projects SET path = ? WHERE id = ?", arguments: [path.path, id.rawValue])
        return .relocated
      }
    }

    /// The thread list, again after every change to threads or projects. Reads no conversation
    /// items, so a stored message reaches it only when it moves a thread's last activity. Each
    /// listed project gets its `shown[project] ?? perProject` newest unarchived threads and every
    /// thread in `always`; `total` counts all of its unarchived threads.
    package func threadGroups(
      shown: [Project.ID: Int], perProject: Int, always: Set<AgentThread.ID>
    ) -> some AsyncSequence<[Project.ID: ThreadGroup], any Error> {
      let limits = "{" + shown.map { "\"\($0.key.rawValue)\":\($0.value)" }.joined(separator: ",") + "}"
      let pinned = "[" + always.map { "\($0.rawValue)" }.joined(separator: ",") + "]"
      return ValueObservation.tracking { db in
        var groups: [Project.ID: (threads: [ThreadSummary], total: Int)] = [:]
        for row in try Row.fetchAll(
          db,
          sql: """
            SELECT id, project_id, title, provider, last_activity_at, total FROM (
              SELECT t.id, t.project_id, t.title, t.provider, t.last_activity_at,
                ROW_NUMBER() OVER (PARTITION BY t.project_id ORDER BY t.last_activity_at DESC, t.id DESC) AS rank,
                COUNT(*) OVER (PARTITION BY t.project_id) AS total
              FROM agent_threads t JOIN agent_projects p ON p.id = t.project_id
              WHERE p.removed_at IS NULL AND t.archived_at IS NULL)
            WHERE rank <= COALESCE(json_extract(?, '$."' || project_id || '"'), ?)
              OR id IN (SELECT value FROM json_each(?))
            ORDER BY project_id, rank
            """,
          arguments: [limits, perProject, pinned])
        {
          guard let provider = AgentProvider(rawValue: row[3]) else { continue }
          let project = Project.ID(row[1])
          groups[project, default: ([], row[5])].threads.append(
            ThreadSummary(
              id: AgentThread.ID(row[0]), projectID: project, title: row[2], provider: provider,
              lastActivityAt: date(unixMilliseconds: row[4])))
        }
        return groups.mapValues { ThreadGroup(threads: $0.threads, total: $0.total) }
      }
      .removeDuplicates()
      .values(in: writer)
    }

    package func thread(_ id: AgentThread.ID) async throws -> AgentThread? {
      try await writer.read { db in
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT id, project_id, provider, provider_session_id, worktree_path, title, title_renamed,
                created_at, last_activity_at, archived_at, permission_mode, model, reasoning
              FROM agent_threads WHERE id = ?
              """,
            arguments: [id.rawValue]),
          let provider = AgentProvider(rawValue: row[2]),
          let mode = PermissionMode(rawValue: row[10])
        else { return nil }
        let archivedAt: Int64? = row[9]
        let rules = try String.fetchAll(
          db, sql: "SELECT rule FROM agent_thread_allow_rules WHERE thread_id = ? ORDER BY rule",
          arguments: [id.rawValue])
        return AgentThread(
          id: id, projectID: Project.ID(row[1]), provider: provider, providerSessionID: row[3],
          worktreePath: row[4], title: row[5], titleRenamed: row[6],
          createdAt: date(unixMilliseconds: row[7]),
          lastActivityAt: date(unixMilliseconds: row[8]), archivedAt: archivedAt.map(date(unixMilliseconds:)),
          permissionMode: mode, model: row[11], reasoning: row[12], allowRules: rules)
      }
    }

    package func insertThread(_ thread: NewThread, allowRules: [String] = []) async throws -> AgentThread.ID {
      try await writer.write { db in
        let created = unixMilliseconds(thread.createdAt)
        try db.execute(
          sql: """
            INSERT INTO agent_threads (project_id, provider, provider_session_id, worktree_path, title,
              created_at, last_activity_at, permission_mode, model, reasoning)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            thread.projectID.rawValue, thread.provider.rawValue, thread.providerSessionID,
            thread.worktreePath,
            thread.title, created, created, thread.permissionMode.rawValue, thread.model, thread.reasoning,
          ])
        let id = db.lastInsertedRowID
        for rule in allowRules {
          try db.execute(
            sql: "INSERT OR IGNORE INTO agent_thread_allow_rules (thread_id, rule) VALUES (?, ?)",
            arguments: [id, rule])
        }
        return AgentThread.ID(id)
      }
    }

    /// The step, in milliseconds, by which a thread's last activity moves. Time labels show minutes
    /// at best, so finer steps would only rewrite the thread, and with it reread the thread list,
    /// on every message a turn streams.
    static let activityGrain: Int64 = 60_000

    /// An item already stored at its seq is skipped, so a replayed append changes nothing. Moves
    /// the thread's last activity to the batch's newest item once that is `activityGrain` or more
    /// newer, taken from the batch, not from a scan of the thread's items.
    package func appendItems(_ items: [NewConversationItem], to thread: AgentThread.ID) async throws {
      let rows = try items.map { item in
        (item, try item.content.bodyJSON())
      }
      let newest = items.map(\.createdAt).max().map(unixMilliseconds)
      try await writer.write { db in
        for (item, body) in rows {
          try db.execute(
            sql: """
              INSERT INTO agent_items (thread_id, seq, kind, request_id, created_at, body_json)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(thread_id, seq) DO NOTHING
              """,
            arguments: [
              thread.rawValue, item.seq, item.content.kind, item.content.requestID,
              unixMilliseconds(item.createdAt), body,
            ])
        }
        guard let newest else { return }
        try db.execute(
          sql: """
            UPDATE agent_threads SET last_activity_at = ?2
            WHERE id = ?1 AND ?2 >= last_activity_at + ?3
            """,
          arguments: [thread.rawValue, newest, Self.activityGrain])
      }
    }

    package func conversation(_ thread: AgentThread.ID) -> some AsyncSequence<[ConversationItem], any Error> {
      ValueObservation.tracking { db in
        try Self.fetchConversation(db, thread)
      }
      .values(in: writer)
    }

    package func conversationItems(_ thread: AgentThread.ID) async throws -> [ConversationItem] {
      try await writer.read { try Self.fetchConversation($0, thread) }
    }

    private static func fetchConversation(_ db: Database, _ thread: AgentThread.ID) throws
      -> [ConversationItem]
    {
      try Row.fetchAll(
        db,
        sql: "SELECT id, seq, created_at, kind, body_json FROM agent_items WHERE thread_id = ? ORDER BY seq",
        arguments: [thread.rawValue]
      ).map { row in
        ConversationItem(
          id: ConversationItem.ID(row[0]), seq: row[1], createdAt: date(unixMilliseconds: row[2]),
          content: ConversationItem.Content(kind: row[3], bodyJSON: row[4]))
      }
    }

    package func draft() async throws -> StartDraft? {
      try await writer.read { db in
        try Row.fetchOne(
          db,
          sql:
            "SELECT project_id, text, provider, permission_mode, model, reasoning FROM agent_draft WHERE id = 1"
        ).map { row in
          let projectID: Int64? = row[0]
          let provider: String? = row[2]
          let mode: String? = row[3]
          return StartDraft(
            projectID: projectID.map(Project.ID.init), text: row[1],
            provider: provider.flatMap(AgentProvider.init(rawValue:)),
            permissionMode: mode.flatMap(PermissionMode.init(rawValue:)), model: row[4], reasoning: row[5])
        }
      }
    }

    /// A draft with no text clears it.
    package func saveDraft(_ draft: StartDraft, now: Date) async throws {
      guard !draft.text.isEmpty else { return try await clearDraft() }
      try await writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO agent_draft (id, project_id, text, provider, permission_mode, model, reasoning, updated_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, text = excluded.text,
              provider = excluded.provider, permission_mode = excluded.permission_mode, model = excluded.model,
              reasoning = excluded.reasoning, updated_at = excluded.updated_at
            """,
          arguments: [
            draft.projectID?.rawValue, draft.text, draft.provider?.rawValue, draft.permissionMode?.rawValue,
            draft.model, draft.reasoning, unixMilliseconds(now),
          ])
      }
    }

    package func clearDraft() async throws {
      try await writer.write { try $0.execute(sql: "DELETE FROM agent_draft") }
    }
  }
#endif
