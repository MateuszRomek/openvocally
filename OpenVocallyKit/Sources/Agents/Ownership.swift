#if FEATURE_AGENTS
  import Foundation

  /// Who put the binary there, read from where it sits. Decides the update recipe and where to ask
  /// for the latest version. This is the one parser of install paths: the prefixes an update acts on
  /// are recorded here, so no other file re-reads Cellar or node_modules paths.
  public enum InstallOwnership: Sendable, Equatable {
    /// `prefix` is everything before `/lib/node_modules/`, the npm prefix that installed it.
    case npm(package: String, prefix: URL)
    /// `prefix` is everything before `Cellar` or `Caskroom`, such as /opt/homebrew.
    case homebrew(HomebrewPackage, prefix: URL)
    /// Updates with its own `update` subcommand.
    case nativeInstaller
    /// Inside another app, such as ChatGPT.app's Codex. It updates with that app: no command, no check.
    case bundled(appName: String)
    case unknown

    /// Reads both the path as found and the resolved path, because a bundled copy can be reached
    /// through a symlink and a Homebrew link in `bin` only names its Cellar once resolved.
    static func classify(found: URL, resolved: URL, spec: AgentSpec, home: URL) -> InstallOwnership {
      for path in [resolved, found] {
        let components = path.standardizedFileURL.pathComponents
        if let app = components.first(where: { $0.hasSuffix(".app") && $0.count > 4 }) {
          return .bundled(appName: String(app.dropLast(4)))
        }
      }
      let components = resolved.standardizedFileURL.pathComponents
      let resolvedPath = resolved.standardizedFileURL.path(percentEncoded: false)
      switch spec.nativeInstaller {
      case .directory(let relative):
        let directory = home.appending(path: relative).standardizedFileURL.path(percentEncoded: false)
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        if resolvedPath.hasPrefix(prefix) { return .nativeInstaller }
      case .pathContains(let fragment):
        if resolvedPath.contains(fragment) { return .nativeInstaller }
      case nil:
        break
      }
      if let range = resolvedPath.range(of: "/lib/node_modules/\(spec.npmPackage)/") {
        let prefix = String(resolvedPath[..<range.lowerBound])
        return .npm(package: spec.npmPackage, prefix: URL(filePath: prefix.isEmpty ? "/" : prefix))
      }
      for (index, component) in components.enumerated() where index + 1 < components.count {
        let name = components[index + 1]
        let package: HomebrewPackage? =
          switch component {
          case "Cellar": .formula(name)
          case "Caskroom": .cask(name)
          default: nil
          }
        if let package {
          guard spec.homebrew.contains(package) else { return .unknown }
          let prefix = "/" + components[1..<index].joined(separator: "/")
          return .homebrew(package, prefix: URL(filePath: prefix))
        }
      }
      return .unknown
    }

    /// How Settings names the install: what put it there, never the path.
    public func title(_ spec: AgentSpec) -> String {
      switch self {
      case .npm: "npm"
      case .homebrew: "Homebrew"
      case .nativeInstaller: "\(spec.displayName) installer"
      case .bundled(let app): "\(app) app"
      case .unknown: "Custom location"
      }
    }

    /// Where the latest version is published. Nil when nothing is checked: a bundled copy, or an
    /// install we cannot attribute.
    func latestVersionSource(_ spec: AgentSpec) -> LatestVersionSource? {
      switch self {
      case .npm(let package, _): .npm(package: package)
      case .homebrew(.formula(let name), _): .homebrewFormula(name)
      case .homebrew(.cask(let name), _): .homebrewCask(name)
      case .nativeInstaller: .npm(package: spec.npmPackage)
      case .bundled, .unknown: nil
      }
    }
  }

  public enum HomebrewPackage: Sendable, Hashable {
    case formula(String)
    case cask(String)
  }
#endif
