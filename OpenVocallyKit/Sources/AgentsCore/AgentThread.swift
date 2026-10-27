#if FEATURE_AGENTS
  import Foundation

  public enum AgentProvider: String, Hashable, Sendable, CaseIterable {
    case claude
    case codex
  }

  public enum PermissionMode: String, Hashable, Sendable, CaseIterable {
    case manual
    case acceptEdits
    case auto
    case fullAccess
  }

  public struct AgentThread: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable, CustomStringConvertible {
      package let rawValue: Int64
      package init(_ rawValue: Int64) { self.rawValue = rawValue }
      public var description: String { "\(rawValue)" }
    }

    public let id: ID
    public let projectID: Project.ID
    public let provider: AgentProvider
    /// Nil until the provider reports its session or thread id.
    public let providerSessionID: String?
    /// Nil when the thread runs in the project folder.
    public let worktreePath: String?
    public let title: String
    package let titleRenamed: Bool
    public let createdAt: Date
    public let lastActivityAt: Date
    public let archivedAt: Date?
    public let permissionMode: PermissionMode
    public let model: String?
    public let reasoning: String?
    package let allowRules: [String]

    package var isArchived: Bool { archivedAt != nil }

    package init(
      id: ID, projectID: Project.ID, provider: AgentProvider, providerSessionID: String?,
      worktreePath: String?,
      title: String, titleRenamed: Bool, createdAt: Date, lastActivityAt: Date, archivedAt: Date?,
      permissionMode: PermissionMode, model: String?, reasoning: String?, allowRules: [String]
    ) {
      self.id = id
      self.projectID = projectID
      self.provider = provider
      self.providerSessionID = providerSessionID
      self.worktreePath = worktreePath
      self.title = title
      self.titleRenamed = titleRenamed
      self.createdAt = createdAt
      self.lastActivityAt = lastActivityAt
      self.archivedAt = archivedAt
      self.permissionMode = permissionMode
      self.model = model
      self.reasoning = reasoning
      self.allowRules = allowRules
    }
  }

  /// What the thread list draws.
  public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public let id: AgentThread.ID
    public let projectID: Project.ID
    public let title: String
    public let provider: AgentProvider
    public let lastActivityAt: Date

    package init(
      id: AgentThread.ID, projectID: Project.ID, title: String, provider: AgentProvider, lastActivityAt: Date
    ) {
      self.id = id
      self.projectID = projectID
      self.title = title
      self.provider = provider
      self.lastActivityAt = lastActivityAt
    }
  }

  /// One project's part of the thread list: its newest unarchived threads up to what the list shows,
  /// plus any thread that needs you, and how many unarchived threads it has in all.
  public struct ThreadGroup: Hashable, Sendable {
    public let threads: [ThreadSummary]
    public let total: Int

    /// The threads "Show more" would add.
    public var hidden: Int { max(0, total - threads.count) }

    package init(threads: [ThreadSummary], total: Int) {
      self.threads = threads
      self.total = total
    }
  }

  /// A new thread row. The engine and the Debug scenario are its only writers.
  package struct NewThread: Sendable {
    package var projectID: Project.ID
    package var provider: AgentProvider
    package var providerSessionID: String?
    package var worktreePath: String?
    package var title: String
    package var createdAt: Date
    package var permissionMode: PermissionMode
    package var model: String?
    package var reasoning: String?

    package init(
      projectID: Project.ID, provider: AgentProvider, providerSessionID: String? = nil,
      worktreePath: String? = nil,
      title: String, createdAt: Date, permissionMode: PermissionMode = .manual, model: String? = nil,
      reasoning: String? = nil
    ) {
      self.projectID = projectID
      self.provider = provider
      self.providerSessionID = providerSessionID
      self.worktreePath = worktreePath
      self.title = title
      self.createdAt = createdAt
      self.permissionMode = permissionMode
      self.model = model
      self.reasoning = reasoning
    }
  }

  /// The parked start-card draft. One at most.
  public struct StartDraft: Hashable, Sendable {
    public var projectID: Project.ID?
    public var text: String
    public var provider: AgentProvider?
    public var permissionMode: PermissionMode?
    public var model: String?
    public var reasoning: String?

    public init(
      projectID: Project.ID? = nil, text: String, provider: AgentProvider? = nil,
      permissionMode: PermissionMode? = nil, model: String? = nil, reasoning: String? = nil
    ) {
      self.projectID = projectID
      self.text = text
      self.provider = provider
      self.permissionMode = permissionMode
      self.model = model
      self.reasoning = reasoning
    }
  }
#endif
