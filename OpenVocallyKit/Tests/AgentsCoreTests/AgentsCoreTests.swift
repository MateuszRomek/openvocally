import Foundation
import Testing

@testable import AgentsCore

struct AgentWorktreesTests {
  @Test func bothBuildsHomesAreExcluded() {
    let home = URL(filePath: "/Users/dev", directoryHint: .isDirectory)
    #expect(
      AgentWorktrees.excludedRoots(home).map(\.path) == [
        "/Users/dev/.openvocally", "/Users/dev/.openvocally-dev",
      ])
    #expect(AgentWorktrees.root(home, debug: true).path == "/Users/dev/.openvocally-dev/worktrees")
  }

  @Test(arguments: [
    ("/Users/dev/.openvocally-dev", true),
    ("/Users/dev/.openvocally-dev/worktrees/app/main", true),
    ("/Users/dev/.openvocally/worktrees/app", true),
    ("/Users/dev/.openvocally-devtools", false),
    ("/Users/dev/Code/.openvocally", false),
    ("/Users/dev", false),
  ])
  func containsComparesWholeComponents(path: String, expected: Bool) {
    let roots = ["/Users/dev/.openvocally", "/Users/dev/.openvocally-dev"]
    #expect(AgentWorktrees.contains(path, roots: roots) == expected)
  }
}

struct ProjectNameTests {
  @Test func blankNamesFallBackToTheFolder() {
    #expect(ProjectName.normalized("  Website \n") == "Website")
    #expect(ProjectName.normalized(" \n\t") == nil)
  }

  @Test func nameIsTheCustomNameOrTheFolderName() {
    let path = ProjectPath(trusted: "/Users/dev/Code/app")
    let added = Date(timeIntervalSince1970: 100)
    let plain = Project(
      id: .init(1), path: path, customName: nil, addedAt: added, lastThreadStartedAt: nil, setupCommand: nil,
      waitsForSetup: true)
    let renamed = Project(
      id: .init(1), path: path, customName: "Website", addedAt: added,
      lastThreadStartedAt: Date(timeIntervalSince1970: 200), setupCommand: nil, waitsForSetup: true)
    #expect(plain.name == "app")
    #expect(renamed.name == "Website")
  }
}

struct ConversationContentTests {
  @Test(arguments: [
    ConversationItem.Content.userMessage(text: "Zażółć"),
    .assistantMessage(text: "Done"),
    .toolStep(ToolStep(name: "Read", summary: "Read a file", succeeded: nil)),
    .request(PermissionRequest(requestID: "r1", tool: "Bash", summary: "ls")),
    .outcome(RequestOutcome(requestID: "r1", decision: .allowedAlways)),
  ])
  func storedFormRoundTrips(_ content: ConversationItem.Content) throws {
    #expect(ConversationItem.Content(kind: content.kind, bodyJSON: try content.bodyJSON()) == content)
  }

  @Test func unknownKindsAndBrokenBodiesAreKept() {
    #expect(ConversationItem.Content(kind: "plan", bodyJSON: "{}") == .unsupported(kind: "plan"))
    #expect(ConversationItem.Content(kind: "user", bodyJSON: "not json") == .unsupported(kind: "user"))
  }

  @Test func onlyRequestsAndOutcomesNameARequest() {
    #expect(
      ConversationItem.Content.outcome(RequestOutcome(requestID: "r9", decision: .denied)).requestID == "r9")
    #expect(ConversationItem.Content.userMessage(text: "hi").requestID == nil)
  }

  @Test func pendingRequestsAreTheOnesWithoutAnOutcome() {
    let date = Date(timeIntervalSince1970: 0)
    let items: [ConversationItem] = [
      .request(PermissionRequest(requestID: "a", tool: "Bash", summary: "ls")),
      .request(PermissionRequest(requestID: "b", tool: "Edit", summary: "x")),
      .outcome(RequestOutcome(requestID: "a", decision: .allowed)),
    ].enumerated().map {
      ConversationItem(id: .init(Int64($0.offset)), seq: $0.offset, createdAt: date, content: $0.element)
    }
    #expect(items.pendingRequestIDs == ["b"])
  }
}
