#if FEATURE_AGENTS
  import Foundation

  public struct ProviderConfiguration: Sendable, Equatable {
    /// Off until the user turns it on: turning a provider on is the consent for its update checks.
    public var enabled = false
    /// Tried first; when it does not run, the walk falls through to the other lookups.
    public var chosenPath: URL?
    public var launchArguments = LaunchArguments("")

    /// Plain keys such as `agentsClaudeEnabled`, so a Debug launch argument of the same name overrides
    /// them from the argument domain without writing the user's defaults.
    public enum Key: String, CaseIterable, Sendable {
      case enabled = "Enabled"
      case path = "Path"
      case launchArguments = "LaunchArguments"

      public func name(for kind: AgentKind) -> String {
        "agents" + kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst() + rawValue
      }
    }

    static func load(_ kind: AgentKind, from defaults: UserDefaults) -> ProviderConfiguration {
      var configuration = ProviderConfiguration()
      configuration.enabled = defaults.bool(forKey: Key.enabled.name(for: kind))
      if let path = defaults.string(forKey: Key.path.name(for: kind)), path.hasPrefix("/") {
        configuration.chosenPath = URL(filePath: path)
      }
      configuration.launchArguments = LaunchArguments(
        defaults.string(forKey: Key.launchArguments.name(for: kind)) ?? "")
      return configuration
    }

    func save(_ kind: AgentKind, to defaults: UserDefaults) {
      defaults.set(enabled, forKey: Key.enabled.name(for: kind))
      defaults.set(chosenPath?.path(percentEncoded: false), forKey: Key.path.name(for: kind))
      defaults.set(launchArguments.text, forKey: Key.launchArguments.name(for: kind))
    }
  }
#endif
