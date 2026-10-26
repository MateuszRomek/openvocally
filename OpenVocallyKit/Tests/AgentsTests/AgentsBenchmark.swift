#if DEBUG
  import AgentsCore
  import Foundation
  import Storage
  import Synchronization
  import Testing

  @testable import Agents

  /// `scripts/agents/agents-bench.sh` runs this with AGENTS_BENCH_OUT set; elsewhere it is skipped.
  /// It seeds the `large` scenario into a database file, as the app opens one, and measures the
  /// thread list the screen reads: how long its first value takes, how many rows it carries, and
  /// how long one stored conversation item takes to reach it again, if it does.
  @MainActor struct AgentsBenchmark {
    nonisolated static let out = ProcessInfo.processInfo.environment["AGENTS_BENCH_OUT"]
    static let runs = 10

    @Test(.enabled(if: out != nil)) func threadList() async throws {
      let temp = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        .appending(path: "agents-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: temp) }
      let database = try AppDatabase.open(at: temp.appending(path: "openvocally.sqlite"))
      let service = try await AgentsScenario.seed(
        .large, database: database, dataFolder: temp, root: temp.appending(path: "agents-folders"))
      var lines: [String] = []
      let clock = ContinuousClock()

      for run in 1...Self.runs {
        let start = clock.now
        var rows = 0
        for try await groups in service.threads() {
          rows = groups.values.reduce(0) { $0 + $1.threads.count }
          break
        }
        lines.append(#"{"case":"list","run":\#(run),"ms":\#(Self.ms(clock.now - start)),"rows":\#(rows)}"#)
      }

      var target: AgentThread.ID?
      for try await groups in service.threads() {
        target = groups.values.flatMap(\.threads).max { $0.lastActivityAt < $1.lastActivityAt }?.id
        break
      }
      let thread = try #require(target)
      for run in 1...Self.runs {
        let seen = Mutex<[ContinuousClock.Instant]>([])
        let watcher = Task {
          for try await _ in service.threads() { seen.withLock { $0.append(clock.now) } }
        }
        try await Self.until { seen.withLock { $0.count } >= 1 }
        let start = clock.now
        try await database.appendItems(
          [NewConversationItem(seq: 10_000 + run, createdAt: .now, content: .assistantMessage(text: "More"))],
          to: thread)
        let refired = (try? await Self.until(limit: .seconds(2)) { seen.withLock { $0.count } >= 2 }) != nil
        watcher.cancel()
        let at = seen.withLock { $0.count >= 2 ? $0[1] : nil }
        lines.append(
          refired && at != nil
            ? #"{"case":"append","run":\#(run),"refired":true,"ms":\#(Self.ms(at! - start))}"#
            : #"{"case":"append","run":\#(run),"refired":false}"#)
      }
      try (lines.joined(separator: "\n") + "\n").write(
        toFile: try #require(Self.out), atomically: true, encoding: .utf8)
    }

    private static func ms(_ duration: Duration) -> String {
      String(
        format: "%.2f",
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    /// Polls `condition` every millisecond; throws once `limit` passes.
    private static func until(limit: Duration = .seconds(30), _ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + limit
      while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }
#endif
