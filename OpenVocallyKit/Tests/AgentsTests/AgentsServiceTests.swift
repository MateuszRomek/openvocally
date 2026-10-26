import AgentsCore
import Foundation
import Storage
import Synchronization
import Testing

@testable import Agents

/// A temp folder holding a fake home and the project folders, an in-memory database and a clock
/// the test moves.
@MainActor final class AgentsFixture {
  let root: URL
  let home: URL
  let database: AppDatabase
  let agents: AgentsService
  private let time = TestClock()

  init() throws {
    let temp = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(path: "agents-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    root = URL(filePath: ProjectPathResolver.realPath(try Self.made(temp).path)!, directoryHint: .isDirectory)
    home = try Self.made(root.appending(path: "home", directoryHint: .isDirectory))
    database = try AppDatabase.inMemory()
    let time = time
    agents = AgentsService(database: database, resolver: ProjectPathResolver(home: home), clock: { time.now })
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  var now: Date { time.now }

  func advance(_ seconds: TimeInterval) {
    time.advance(seconds)
  }

  /// Creates `path` under the fixture root.
  func folder(_ path: String) throws -> URL {
    try Self.made(root.appending(path: path, directoryHint: .isDirectory))
  }

  func path(_ path: String) -> String {
    root.appending(path: path).path
  }

  func add(_ path: String) async throws -> Project.ID {
    let outcome = try await agents.addProject(at: try folder(path))
    guard case .added(let id) = outcome else {
      Issue.record("Adding \(path) returned \(outcome)")
      throw CancellationError()
    }
    return id
  }

  func thread(in project: Project.ID, title: String, startedAt: Date) async throws -> AgentThread.ID {
    try await database.insertThread(
      NewThread(projectID: project, provider: .claude, title: title, createdAt: startedAt))
  }

  func threads(in project: Project.ID) async throws -> [ThreadSummary] {
    try await group(project, shown: [:]).threads
  }

  func group(_ project: Project.ID, shown: [Project.ID: Int] = [:]) async throws -> ThreadGroup {
    for try await groups in agents.threads(shown: shown) {
      return groups[project] ?? ThreadGroup(threads: [], total: 0)
    }
    return ThreadGroup(threads: [], total: 0)
  }

  var names: [String] { agents.projects.map(\.project.name) }

  private static func made(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

final class TestClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
  var now: Date { date.withLock { $0 } }
  func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

@MainActor struct AddProjectTests {
  @Test func addingAFolderListsIt() async throws {
    let fixture = try AgentsFixture()
    _ = try await fixture.add("app")
    #expect(fixture.agents.projects.map(\.project.path.path) == [fixture.path("app")])
    #expect(fixture.agents.projects.map(\.health) == [.available])
    #expect(fixture.names == ["app"])
  }

  @Test func addingItAgainReturnsTheExistingProject() async throws {
    let fixture = try AgentsFixture()
    let first = try await fixture.add("app")
    _ = try await fixture.add("other")
    #expect(try await fixture.agents.addProject(at: try fixture.folder("app")) == .existing(first))
    #expect(fixture.agents.projects.count == 2)
  }

  @Test func aSymlinkAndAnotherCaseDedupeToTheSameProject() async throws {
    let fixture = try AgentsFixture()
    let first = try await fixture.add("Code/App")
    let link = fixture.root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try fixture.folder("Code/App"))
    #expect(try await fixture.agents.addProject(at: link) == .existing(first))
    let otherCase = fixture.root.appending(path: "code/app", directoryHint: .isDirectory)
    #expect(try await fixture.agents.addProject(at: otherCase) == .existing(first))
    let dotted = fixture.root.appending(path: "Code/App/../App", directoryHint: .isDirectory)
    #expect(try await fixture.agents.addProject(at: dotted) == .existing(first))
    #expect(fixture.agents.projects.map(\.project.path.path) == [fixture.path("Code/App")])
  }

  @Test func aSubfolderStaysASubfolder() async throws {
    let fixture = try AgentsFixture()
    _ = try await fixture.add("repo")
    try FileManager.default.createDirectory(
      at: fixture.root.appending(path: "repo/.git"), withIntermediateDirectories: true)
    _ = try await fixture.add("repo/docs")
    #expect(
      Set(fixture.agents.projects.map(\.project.path.path)) == [
        fixture.path("repo"), fixture.path("repo/docs"),
      ])
    #expect(fixture.names.first == "docs")
  }

  @Test(arguments: [
    "home/.openvocally/worktrees/app/main", "home/.openvocally-dev/worktrees/app", "home/.openvocally-dev",
  ])
  func ownWorktreesAreRejected(_ path: String) async throws {
    let fixture = try AgentsFixture()
    #expect(
      try await fixture.agents.addProject(at: try fixture.folder(path)) == .rejected(.openVocallyWorktree))
    #expect(fixture.agents.projects.isEmpty)
  }

  @Test func aFolderNamedLikeAWorktreeHomeIsAllowed() async throws {
    let fixture = try AgentsFixture()
    let outcome = try await fixture.agents.addProject(at: try fixture.folder("home/.openvocally-devtools"))
    #expect(fixture.agents.projects.map(\.id).map(AddProjectOutcome.added) == [outcome])
  }

  @Test func filesAndMissingPathsAreRejected() async throws {
    let fixture = try AgentsFixture()
    let file = fixture.root.appending(path: "notes.txt")
    try Data("x".utf8).write(to: file)
    #expect(try await fixture.agents.addProject(at: file) == .rejected(.notAFolder))
    #expect(
      try await fixture.agents.addProject(at: fixture.root.appending(path: "nowhere"))
        == .rejected(.notAFolder))
    #expect(fixture.agents.projects.isEmpty)
  }
}

@MainActor struct EditProjectTests {
  @Test func renameAndClearingTheRename() async throws {
    let fixture = try AgentsFixture()
    let id = try await fixture.add("app")
    try await fixture.agents.rename(id, to: "  Website  ")
    #expect(fixture.names == ["Website"])
    #expect(fixture.agents.projects.first?.project.customName == "Website")
    try await fixture.agents.rename(id, to: " ")
    #expect(fixture.names == ["app"])
    #expect(fixture.agents.projects.first?.project.customName == nil)
  }

  @Test func removeArchivesThreadsAndReAddingRestoresThemArchived() async throws {
    let fixture = try AgentsFixture()
    let id = try await fixture.add("app")
    _ = try await fixture.add("other")
    let thread = try await fixture.thread(in: id, title: "Fix it", startedAt: fixture.now)
    fixture.advance(60)
    let removedAt = fixture.now
    try await fixture.agents.remove(id)
    #expect(fixture.names == ["other"])
    #expect(try await fixture.database.thread(thread)?.archivedAt == removedAt)
    #expect(try await fixture.threads(in: id).isEmpty)

    fixture.advance(60)
    try await fixture.agents.remove(id)
    #expect(try await fixture.database.thread(thread)?.archivedAt == removedAt)

    #expect(try await fixture.agents.addProject(at: try fixture.folder("app")) == .restored(id))
    #expect(Set(fixture.names) == ["app", "other"])
    #expect(try await fixture.threads(in: id).isEmpty)
    #expect(try await fixture.database.thread(thread)?.archivedAt == removedAt)
  }

  @Test func aFailedLoadIsReported() async throws {
    let fixture = try AgentsFixture()
    try fixture.database.close()
    let agents = AgentsService(database: fixture.database)
    await #expect(throws: (any Error).self) { try await agents.load() }
    #expect(agents.loadFailed)
    #expect(agents.projects.isEmpty)
  }

  @Test func removingTheLastProjectEmptiesTheList() async throws {
    let fixture = try AgentsFixture()
    let id = try await fixture.add("app")
    try await fixture.agents.remove(id)
    #expect(fixture.agents.projects.isEmpty)
  }
}

@MainActor struct LocateTests {
  @Test func aMissingFolderIsReportedMissing() async throws {
    let fixture = try AgentsFixture()
    _ = try await fixture.add("app")
    try FileManager.default.removeItem(at: fixture.root.appending(path: "app"))
    await fixture.agents.refreshHealth()
    #expect(fixture.agents.projects.map(\.health) == [.missing])
    let reloaded = AgentsService(database: fixture.database)
    try await reloaded.load()
    #expect(reloaded.projects.map(\.health) == [.available])
    await reloaded.refreshHealth()
    #expect(reloaded.projects.map(\.health) == [.missing])
  }

  @Test func locateMovesTheProjectAndKeepsItsThreads() async throws {
    let fixture = try AgentsFixture()
    let id = try await fixture.add("app")
    try await fixture.agents.rename(id, to: "Website")
    _ = try await fixture.thread(in: id, title: "Fix it", startedAt: fixture.now)
    try FileManager.default.moveItem(
      at: fixture.root.appending(path: "app"), to: fixture.root.appending(path: "moved"))
    await fixture.agents.refreshHealth()
    #expect(fixture.agents.projects.map(\.health) == [.missing])

    #expect(try await fixture.agents.locate(id, at: fixture.root.appending(path: "moved")) == .relocated)
    #expect(fixture.agents.projects.map(\.project.path.path) == [fixture.path("moved")])
    #expect(fixture.agents.projects.map(\.health) == [.available])
    #expect(fixture.names == ["Website"])
    #expect(try await fixture.threads(in: id).map(\.title) == ["Fix it"])
    #expect(try await fixture.agents.locate(id, at: fixture.root.appending(path: "moved")) == .unchanged)
  }

  @Test func locatingAnotherProjectsFolderReturnsItAndWritesNothing() async throws {
    let fixture = try AgentsFixture()
    let app = try await fixture.add("app")
    let other = try await fixture.add("other")
    #expect(try await fixture.agents.locate(app, at: try fixture.folder("other")) == .alreadyAProject(other))
    #expect(
      Set(fixture.agents.projects.map(\.project.path.path)) == [fixture.path("app"), fixture.path("other")])
  }

  @Test func locateRejectsWhatAddRejects() async throws {
    let fixture = try AgentsFixture()
    let app = try await fixture.add("app")
    #expect(
      try await fixture.agents.locate(app, at: try fixture.folder("home/.openvocally/worktrees/x"))
        == .rejected(.openVocallyWorktree))
    #expect(
      try await fixture.agents.locate(app, at: fixture.root.appending(path: "nowhere"))
        == .rejected(.notAFolder))
    #expect(fixture.agents.projects.map(\.project.path.path) == [fixture.path("app")])
  }
}

@MainActor struct ProjectOrderTests {
  @Test func projectsAreOrderedByTheirLastThreadStarted() async throws {
    let fixture = try AgentsFixture()
    let a = try await fixture.add("a")
    fixture.advance(10)
    let b = try await fixture.add("b")
    fixture.advance(10)
    _ = try await fixture.add("c")
    #expect(fixture.names == ["c", "b", "a"])

    _ = try await fixture.thread(in: a, title: "1", startedAt: fixture.now + 100)
    _ = try await fixture.thread(in: b, title: "2", startedAt: fixture.now + 50)
    try await fixture.agents.load()
    #expect(fixture.names == ["a", "b", "c"])
    #expect(fixture.agents.projects.first?.project.lastThreadStartedAt == fixture.now + 100)

    _ = try await fixture.thread(in: b, title: "3", startedAt: fixture.now + 200)
    try await fixture.agents.load()
    #expect(fixture.names == ["b", "a", "c"])
  }
}

@MainActor struct ThreadDataTests {
  @Test func draftSavesLoadsAndClears() async throws {
    let fixture = try AgentsFixture()
    let id = try await fixture.add("app")
    #expect(try await fixture.agents.draft() == nil)
    let draft = StartDraft(
      projectID: id, text: "Add dark mode", provider: .codex, permissionMode: .auto, model: "o4")
    try await fixture.agents.saveDraft(draft)
    #expect(try await fixture.agents.draft() == draft)
    try await fixture.agents.saveDraft(StartDraft(text: "Second"))
    #expect(try await fixture.agents.draft() == StartDraft(text: "Second"))
    try await fixture.agents.saveDraft(StartDraft(text: ""))
    #expect(try await fixture.agents.draft() == nil)
    try await fixture.agents.saveDraft(draft)
    try await fixture.agents.clearDraft()
    #expect(try await fixture.agents.draft() == nil)
  }

  /// A resumed session runs a new process, which numbers its requests from the start again.
  @Test func aReusedRequestIDKeepsEveryItem() async throws {
    let fixture = try AgentsFixture()
    let project = try await fixture.add("app")
    let thread = try await fixture.thread(in: project, title: "Fix it", startedAt: fixture.now)
    let first = PermissionRequest(requestID: "0", tool: "Bash", summary: "make test")
    let again = PermissionRequest(requestID: "0", tool: "Edit", summary: "App.swift")
    try await fixture.database.appendItems(
      [
        NewConversationItem(seq: 1, createdAt: fixture.now, content: .request(first)),
        NewConversationItem(
          seq: 2, createdAt: fixture.now,
          content: .outcome(RequestOutcome(requestID: "0", decision: .allowed))),
      ], to: thread)
    try await fixture.database.appendItems(
      [
        NewConversationItem(seq: 3, createdAt: fixture.now + 5, content: .request(again)),
        NewConversationItem(
          seq: 4, createdAt: fixture.now + 9,
          content: .outcome(RequestOutcome(requestID: "0", decision: .denied))),
      ], to: thread)
    #expect(try await fixture.database.conversationItems(thread).map(\.seq) == [1, 2, 3, 4])
  }

  @Test func lastActivityMovesByTheMinute() async throws {
    let fixture = try AgentsFixture()
    let project = try await fixture.add("app")
    let thread = try await fixture.thread(in: project, title: "Fix it", startedAt: fixture.now)
    try await fixture.database.appendItems(
      [NewConversationItem(seq: 1, createdAt: fixture.now + 59, content: .userMessage(text: "Hi"))],
      to: thread)
    #expect(try await fixture.database.thread(thread)?.lastActivityAt == fixture.now)
    try await fixture.database.appendItems(
      [NewConversationItem(seq: 2, createdAt: fixture.now + 61, content: .userMessage(text: "Hi"))],
      to: thread)
    #expect(try await fixture.database.thread(thread)?.lastActivityAt == fixture.now + 61)
  }

  @Test func eachProjectShowsItsNewestThreadsFirst() async throws {
    let fixture = try AgentsFixture()
    let project = try await fixture.add("app")
    var threads: [AgentThread.ID] = []
    for index in 0..<8 {
      threads.append(
        try await fixture.thread(in: project, title: "T\(index)", startedAt: fixture.now + Double(index)))
    }
    let first = try await fixture.group(project)
    #expect(first.threads.map(\.title) == ["T7", "T6", "T5", "T4", "T3"])
    #expect(first.hidden == 3)
    let all = try await fixture.group(project, shown: [project: 30])
    #expect(all.threads.count == 8)
    #expect(all.hidden == 0)

    fixture.agents.setWaiting(threads[0], true)
    #expect(try await fixture.group(project).threads.map(\.title) == ["T7", "T6", "T5", "T4", "T3", "T0"])
    fixture.agents.setWaiting(threads[0], false)
    #expect(try await fixture.group(project).threads.map(\.title).last == "T3")
  }

  @Test func theOpenThreadStaysListedPastItsProjectsLimit() async throws {
    let fixture = try AgentsFixture()
    let project = try await fixture.add("app")
    var threads: [AgentThread.ID] = []
    for index in 0..<8 {
      threads.append(
        try await fixture.thread(in: project, title: "T\(index)", startedAt: fixture.now + Double(index)))
    }
    var titles: [String] = []
    for try await groups in fixture.agents.threads(keeping: threads[1]) {
      titles = groups[project]?.threads.map(\.title) ?? []
      break
    }
    #expect(titles == ["T7", "T6", "T5", "T4", "T3", "T1"])
  }

  @Test func replayingAnAppendChangesNothing() async throws {
    let fixture = try AgentsFixture()
    let project = try await fixture.add("app")
    let thread = try await fixture.thread(in: project, title: "Fix it", startedAt: fixture.now)
    let items = [NewConversationItem(seq: 1, createdAt: fixture.now, content: .userMessage(text: "Hi"))]
    try await fixture.database.appendItems(items, to: thread)
    try await fixture.database.appendItems(
      [NewConversationItem(seq: 1, createdAt: fixture.now, content: .userMessage(text: "Changed"))],
      to: thread)
    #expect(try await fixture.database.conversationItems(thread).map(\.content) == [.userMessage(text: "Hi")])
  }
}

#if DEBUG
  @MainActor struct AgentsScenarioTests {
    @Test func folderMissingSeedsFourProjectsWithOneMissing() async throws {
      let fixture = try AgentsFixture()
      let service = try await AgentsScenario.seed(
        .folderMissing, database: fixture.database, dataFolder: fixture.root,
        root: fixture.root.appending(path: "agents-folders"), now: fixture.now)
      #expect(service.projects.map(\.project.name) == ["openvocally", "Marketing Site", "docs", "notes-api"])
      #expect(service.projects.map(\.health) == [.available, .available, .available, .missing])
      let first = try #require(service.projects.first?.id)
      var titles: [String] = []
      for try await groups in service.threads() {
        titles = groups[first]?.threads.map(\.title) ?? []
        break
      }
      #expect(titles == ["Fix the paste delay", "Update the menu bar icon"])
      #expect(service.waiting.count == 1)
    }

    @Test func aRootOutsideTheDataFolderIsRefused() async throws {
      let fixture = try AgentsFixture()
      await #expect(throws: AgentsScenario.Refusal.self) {
        _ = try await AgentsScenario.seed(
          .projects, database: fixture.database, dataFolder: fixture.root.appending(path: "data"),
          root: fixture.root.appending(path: "agents-folders"))
      }
    }
  }
#endif
