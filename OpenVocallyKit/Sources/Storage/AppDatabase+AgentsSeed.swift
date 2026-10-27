#if FEATURE_AGENTS && DEBUG
  import AgentsCore
  import Foundation
  import GRDB

  extension AppDatabase {
    /// Measurement data for `scripts/agents/agents-bench.sh` and the `large` scenario: for each
    /// project, `threads` threads of `items` items each, newest at `now`, one minute apart. Every
    /// tenth thread ends on a request with no outcome. One transaction, so 240,000 items seed in
    /// seconds instead of one write per thread. Returns each project's eleventh-newest thread, past
    /// the list's first page, for the scenario to mark as waiting.
    @discardableResult
    package func seedAgentThreads(
      projects: [Project.ID], threads: Int, items: Int, now: Date
    ) async throws -> [AgentThread.ID] {
      let nowMs = unixMilliseconds(now)
      let request = try ConversationItem.Content.request(
        PermissionRequest(requestID: "seed", tool: "Bash", summary: "make test")
      ).bodyJSON()
      let message = try ConversationItem.Content.userMessage(text: "Seeded message").bodyJSON()
      return try await writer.write { db in
        var eleventh: [AgentThread.ID] = []
        let thread = try db.makeStatement(
          sql: """
            INSERT INTO agent_threads (project_id, provider, title, created_at, last_activity_at,
              permission_mode)
            VALUES (?, ?, ?, ?, ?, 'auto')
            """)
        let item = try db.makeStatement(
          sql: """
            INSERT INTO agent_items (thread_id, seq, kind, request_id, created_at, body_json)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        var age: Int64 = 0
        for index in 0..<threads {
          for project in projects {
            age += 60_000
            let at = nowMs - age
            try thread.execute(arguments: [
              project.rawValue, index.isMultiple(of: 2) ? "claude" : "codex", "Seeded thread \(index + 1)",
              at, at,
            ])
            let id = db.lastInsertedRowID
            if index == 10 { eleventh.append(AgentThread.ID(id)) }
            for seq in 1...items {
              let asks = seq == items && index.isMultiple(of: 10)
              try item.execute(arguments: [
                id, seq, asks ? "request" : "user", asks ? "seed" : nil, at, asks ? request : message,
              ])
            }
          }
        }
        return eleventh
      }
    }
  }
#endif
