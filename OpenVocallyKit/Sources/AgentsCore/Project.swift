#if FEATURE_AGENTS
  import Foundation

  /// A folder the user added. A rename stores `customName`; clearing it shows the folder's name
  /// again, so a located folder's new name shows unless the user renamed the project.
  public struct Project: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable, CustomStringConvertible {
      /// `package`, so the App gets ids only from the service and cannot mint them.
      package let rawValue: Int64
      package init(_ rawValue: Int64) { self.rawValue = rawValue }
      public var description: String { "\(rawValue)" }
    }

    public let id: ID
    public let path: ProjectPath
    public let customName: String?
    package let addedAt: Date
    /// Derived by the list query from the project's threads, never stored.
    public let lastThreadStartedAt: Date?
    package let setupCommand: String?
    package let waitsForSetup: Bool

    public var name: String { customName ?? path.folderName }

    package init(
      id: ID, path: ProjectPath, customName: String?, addedAt: Date, lastThreadStartedAt: Date?,
      setupCommand: String?, waitsForSetup: Bool
    ) {
      self.id = id
      self.path = path
      self.customName = customName
      self.addedAt = addedAt
      self.lastThreadStartedAt = lastThreadStartedAt
      self.setupCommand = setupCommand
      self.waitsForSetup = waitsForSetup
    }
  }

  /// A folder path that passed `ProjectPathResolver`: absolute, with symlinks and `..` resolved, in
  /// the on-disk case, and outside OpenVocally's own worktrees. It is the dedupe key and the stored
  /// column. Only the resolver and Storage, reading a stored row, can build one, so no caller can
  /// store an unchecked path.
  public struct ProjectPath: Hashable, Sendable {
    public let path: String
    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
    public var folderName: String { url.lastPathComponent }

    package init(trusted path: String) { self.path = path }
  }

  /// Why a folder can't be a project.
  public enum ProjectPathRejection: Error, Hashable, Sendable {
    /// A file, or nothing at that path.
    case notAFolder
    /// Inside `~/.openvocally` or `~/.openvocally-dev`, where threads get their worktrees.
    case openVocallyWorktree
  }

  /// Checked off the main actor on every load, never stored: a folder can go missing while the app
  /// is closed.
  public enum FolderHealth: Hashable, Sendable {
    case available
    case missing
  }

  /// What the sidebar draws for one project.
  public struct ProjectRow: Identifiable, Hashable, Sendable {
    public let project: Project
    public let health: FolderHealth
    public var id: Project.ID { project.id }

    package init(project: Project, health: FolderHealth) {
      self.project = project
      self.health = health
    }
  }

  public enum ProjectName {
    /// Trims whitespace and newlines; nil means "use the folder's name".
    public static func normalized(_ input: String) -> String? {
      let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  /// Where OpenVocally keeps thread worktrees. The resolver refuses folders under any of them, in
  /// every build, and the worktree code creates worktrees under `root`, so both read one list.
  public enum AgentWorktrees {
    /// `~/.openvocally` for Release, `~/.openvocally-dev` for Debug, so the builds keep separate data.
    public static func home(_ home: URL, debug: Bool) -> URL {
      home.appending(path: debug ? ".openvocally-dev" : ".openvocally", directoryHint: .isDirectory)
    }

    public static func root(_ home: URL, debug: Bool) -> URL {
      Self.home(home, debug: debug).appending(path: "worktrees", directoryHint: .isDirectory)
    }

    /// Both builds' homes: a Debug app must not add a Release worktree either.
    public static func excludedRoots(_ home: URL) -> [URL] {
      [Self.home(home, debug: false), Self.home(home, debug: true)]
    }

    /// Compares path components, so `~/.openvocally-devtools` is not under `~/.openvocally-dev`.
    public static func contains(_ path: String, roots: [String]) -> Bool {
      let components = URL(filePath: path).standardizedFileURL.pathComponents
      return roots.contains { root in
        let rootComponents = URL(filePath: root).standardizedFileURL.pathComponents
        return components.count >= rootComponents.count
          && Array(components.prefix(rootComponents.count)) == rootComponents
      }
    }
  }
#endif
