#if FEATURE_AGENTS
  import Foundation

  /// The sidebar's one prompt for every provider with an unseen update, in `AgentKind` order.
  /// Never empty: there is no notice without a first item.
  public struct AgentUpdateNotice: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
      public let kind: AgentKind
      public let latest: CLIVersion
    }

    public let first: Item
    public let rest: [Item]

    public var updates: [Item] { [first] + rest }

    /// Nil for no items.
    init?(_ items: [Item]) {
      guard let first = items.first else { return nil }
      self.first = first
      rest = Array(items.dropFirst())
    }

    /// Every enabled provider with an available update not seen at that version, while no update
    /// of its own runs. Opening or dismissing the notice marks each version seen, so only a newer
    /// one brings it back.
    init?(states: [AgentHealthService.State], seen: [AgentKind: CLIVersion]) {
      self.init(
        states.compactMap { state in
          guard state.configuration.enabled, !state.updateRun.isActive,
            case .available(let latest) = state.update, seen[state.kind] != latest
          else { return nil }
          return Item(kind: state.kind, latest: latest)
        })
    }

    /// Settings opens at this provider.
    public var firstKind: AgentKind { first.kind }

    public var title: String { rest.isEmpty ? "Update Available" : "Updates Available" }

    public var detail: String {
      if rest.isEmpty { return "\(first.kind.spec.displayName) \(first.latest)" }
      return updates.map(\.kind.spec.displayName).formatted(.list(type: .and))
    }
  }
#endif
