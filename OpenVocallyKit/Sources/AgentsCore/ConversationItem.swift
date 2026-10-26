#if FEATURE_AGENTS
  import Foundation

  /// The stored conversation copy: normalized items, never provider frames. `seq` orders items in a
  /// thread, and (thread, seq) is unique, so replaying an append changes nothing.
  public struct ConversationItem: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
      package let rawValue: Int64
      package init(_ rawValue: Int64) { self.rawValue = rawValue }
    }

    public let id: ID
    public let seq: Int
    public let createdAt: Date
    public let content: Content

    package init(id: ID, seq: Int, createdAt: Date, content: Content) {
      self.id = id
      self.seq = seq
      self.createdAt = createdAt
      self.content = content
    }

    public enum Content: Hashable, Sendable {
      case userMessage(text: String)
      case assistantMessage(text: String)
      case toolStep(ToolStep)
      case request(PermissionRequest)
      case outcome(RequestOutcome)
      /// A kind this build does not know, written by a newer build. Kept, drawn as nothing.
      case unsupported(kind: String)
    }
  }

  public struct ToolStep: Hashable, Sendable, Codable {
    public let name: String
    public let summary: String
    package let succeeded: Bool?

    public init(name: String, summary: String, succeeded: Bool?) {
      self.name = name
      self.summary = summary
      self.succeeded = succeeded
    }
  }

  public struct PermissionRequest: Hashable, Sendable, Codable {
    /// The provider's id for the request; its outcome names it.
    public let requestID: String
    public let tool: String
    public let summary: String

    public init(requestID: String, tool: String, summary: String) {
      self.requestID = requestID
      self.tool = tool
      self.summary = summary
    }
  }

  public struct RequestOutcome: Hashable, Sendable, Codable {
    public enum Decision: String, Hashable, Sendable, Codable { case allowed, allowedAlways, denied }
    public let requestID: String
    public let decision: Decision

    public init(requestID: String, decision: Decision) {
      self.requestID = requestID
      self.decision = decision
    }
  }

  package struct NewConversationItem: Sendable {
    package var seq: Int
    package var createdAt: Date
    package var content: ConversationItem.Content

    package init(seq: Int, createdAt: Date, content: ConversationItem.Content) {
      self.seq = seq
      self.createdAt = createdAt
      self.content = content
    }
  }

  /// The stored form: a `kind` column, the request id it names, if any, and a JSON body. One switch
  /// each way, so the column and the body can't disagree.
  extension ConversationItem.Content {
    private struct Message: Codable { let text: String }

    package var kind: String {
      switch self {
      case .userMessage: "user"
      case .assistantMessage: "assistant"
      case .toolStep: "tool"
      case .request: "request"
      case .outcome: "outcome"
      case .unsupported(let kind): kind
      }
    }

    package var requestID: String? {
      switch self {
      case .request(let request): request.requestID
      case .outcome(let outcome): outcome.requestID
      default: nil
      }
    }

    package func bodyJSON() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let data: Data =
        switch self {
        case .userMessage(let text), .assistantMessage(let text): try encoder.encode(Message(text: text))
        case .toolStep(let step): try encoder.encode(step)
        case .request(let request): try encoder.encode(request)
        case .outcome(let outcome): try encoder.encode(outcome)
        case .unsupported: Data("{}".utf8)
        }
      return String(decoding: data, as: UTF8.self)
    }

    /// A body this build can't read becomes `.unsupported`, so one bad row never hides the rest.
    package init(kind: String, bodyJSON: String) {
      let decoder = JSONDecoder()
      let data = Data(bodyJSON.utf8)
      switch kind {
      case "user":
        self =
          (try? decoder.decode(Message.self, from: data)).map { .userMessage(text: $0.text) }
          ?? .unsupported(kind: kind)
      case "assistant":
        self =
          (try? decoder.decode(Message.self, from: data)).map { .assistantMessage(text: $0.text) }
          ?? .unsupported(kind: kind)
      case "tool":
        self = (try? decoder.decode(ToolStep.self, from: data)).map(Self.toolStep) ?? .unsupported(kind: kind)
      case "request":
        self =
          (try? decoder.decode(PermissionRequest.self, from: data)).map(Self.request)
          ?? .unsupported(kind: kind)
      case "outcome":
        self =
          (try? decoder.decode(RequestOutcome.self, from: data)).map(Self.outcome) ?? .unsupported(kind: kind)
      default:
        self = .unsupported(kind: kind)
      }
    }
  }

  extension [ConversationItem] {
    /// The ids of the requests in this conversation that have no outcome yet.
    public var pendingRequestIDs: Set<String> {
      var pending = Set<String>()
      for item in self {
        switch item.content {
        case .request(let request): pending.insert(request.requestID)
        case .outcome(let outcome): pending.remove(outcome.requestID)
        default: continue
        }
      }
      return pending
    }
  }
#endif
