#if FEATURE_AGENTS
  import AgentsCore
  import Darwin
  import Foundation

  /// Turns a folder the user chose into a `ProjectPath`, the only constructor the App can reach. It
  /// keeps the folder as chosen: a subfolder of a repository stays that subfolder.
  public struct ProjectPathResolver: Sendable {
    /// Resolved once, so a symlinked home still matches.
    let excludedRoots: [String]

    public init(home: URL = .homeDirectory) {
      excludedRoots = AgentWorktrees.excludedRoots(home).map {
        Self.realPath($0.path) ?? $0.standardizedFileURL.path
      }
    }

    /// `realpath(3)` resolves symlinks, `..` and `/private` firmlinks, and on Darwin returns the
    /// on-disk case, so two spellings of one folder on a case-insensitive volume dedupe.
    @concurrent public func resolve(_ url: URL) async -> Result<ProjectPath, ProjectPathRejection> {
      guard let path = Self.realPath(url.path), FolderHealthCheck.isDirectory(path) else {
        return .failure(.notAFolder)
      }
      guard !AgentWorktrees.contains(path, roots: excludedRoots) else {
        return .failure(.openVocallyWorktree)
      }
      return .success(ProjectPath(trusted: path))
    }

    static func realPath(_ path: String) -> String? {
      guard let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    }
  }

  /// Stats a folder off the main actor, so a hung network volume delays its health, never the UI.
  enum FolderHealthCheck {
    @concurrent static func health(of path: ProjectPath) async -> FolderHealth {
      isDirectory(path.path) ? .available : .missing
    }

    static func isDirectory(_ path: String) -> Bool {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
  }
#endif
