#if FEATURE_AGENTS
  import Agents
  import AppKit
  import Foundation
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "agents-harness")

  /// Launch arguments that let `scripts/agents/agents-shots.sh` show Settings → Agents against the
  /// fake CLIs, with no real CLI, no network and no write to the user's defaults:
  ///
  /// - `-agentsSettings YES` opens Settings and scrolls to `-agentsScrollTo claude|codex`.
  /// - `-agentsSearchOnly YES` tries only the chosen path, then the directories in
  ///   `-agentsSearchDirectories /a:/b`, so a CLI installed on this Mac never runs.
  /// - `-agentsLatest claude=9.9.9,codex=0.200.0` answers the latest-version check.
  /// - `-agentsAppearance aqua|darkAqua` sets the app's appearance. Increase Contrast comes only
  ///   from the system setting: a forced high-contrast appearance draws the same pixels as dark.
  /// - `-agentsOpenNotice YES` starts on Home and opens the sidebar's update notice as soon as the
  ///   first check finds one, so Settings opens with its scroll target already set.
  /// - `-agentsInstallUpdate claude|codex` runs that provider's update once both settle, as the
  ///   Update button would, so a shot shows its result without a click.
  /// - `-agentsReadyFile /abs/file` creates that file once both providers settle, and any update
  ///   has finished, so the script knows when to read the accessibility tree and capture the window.
  ///
  /// The provider settings themselves come from `-agentsClaudeEnabled YES -agentsClaudePath /abs`
  /// (and the Codex keys), which the argument domain overrides without writing to disk.
  @MainActor enum AgentsHarness {
    private static var defaults: UserDefaults { .standard }

    static var isRequested: Bool { defaults.bool(forKey: "agentsSettings") }

    /// The user's defaults, except under `-agentsSettings`: then a scratch domain seeded only from
    /// the launch arguments, never from the persistent Dev domain, so the update cache and any
    /// toggle stay out of the user's Dev defaults, a provider the user set up in the Dev app never
    /// leaks into a shot, and a cached real answer never hides `-agentsLatest`.
    static func serviceDefaults() -> UserDefaults {
      let name = "com.openvocally.app.debug.agents-harness"
      guard isRequested, let scratch = UserDefaults(suiteName: name) else { return .standard }
      scratch.removePersistentDomain(forName: name)
      let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      for kind in AgentKind.allCases {
        for key in ProviderConfiguration.Key.allCases.map({ $0.name(for: kind) }) {
          scratch.set(arguments[key], forKey: key)
        }
      }
      return scratch
    }

    static func environment() -> AgentEnvironment {
      var environment = AgentEnvironment.live()
      if defaults.bool(forKey: "agentsSearchOnly") {
        let directories = (defaults.string(forKey: "agentsSearchDirectories") ?? "")
          .split(separator: ":").filter { $0.hasPrefix("/") }
          .map { URL(filePath: String($0), directoryHint: .isDirectory) }
        environment.search = .only(
          directories: directories, environment: ProcessInfo.processInfo.environment)
      }
      if let answer = defaults.string(forKey: "agentsLatest") {
        let latest = latestVersions(answer)
        environment.latestVersions = { source in
          guard let kind = source.kind, let version = latest[kind] else { throw NoAnswer() }
          return version
        }
      }
      return environment
    }

    private struct NoAnswer: Error {}

    private static func latestVersions(_ answer: String) -> [AgentKind: CLIVersion] {
      var latest: [AgentKind: CLIVersion] = [:]
      for pair in answer.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = AgentKind(rawValue: parts[0]), let version = CLIVersion(parts[1])
        else { continue }
        latest[kind] = version
      }
      return latest
    }

    static func run(_ model: AppModel) async {
      let opensNotice = defaults.bool(forKey: "agentsOpenNotice")
      model.screen = opensNotice ? .home : .settings
      guard let window = await mainWindow(model) else {
        logger.error("Agents settings: no main window")
        return
      }
      // App-wide, so SwiftUI's color scheme and contrast follow it, not only the window's views.
      if let name = defaults.string(forKey: "agentsAppearance") {
        NSApp.appearance = appearance(name).flatMap(NSAppearance.init(named:))
      }
      if let visible = window.screen?.visibleFrame {
        window.setFrame(
          NSRect(x: visible.minX, y: visible.minY, width: 760, height: visible.height), display: true)
      }
      await model.agents.refresh(.launch).value
      if opensNotice {
        if let notice = model.agents.updateNotice {
          model.openAgentUpdate(notice)
        } else {
          logger.error("Agents settings: no update notice to open")
        }
      }
      for _ in 0..<100 where AgentKind.allCases.contains(where: { model.agents[$0].health == .checking }) {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(1))
      if !opensNotice {
        let kind = defaults.string(forKey: "agentsScrollTo").flatMap(AgentKind.init(rawValue:)) ?? .claude
        model.settingsAnchor = AgentsSections.sectionID(kind)
      }
      if let update = defaults.string(forKey: "agentsInstallUpdate").flatMap(AgentKind.init(rawValue:)) {
        await model.agents.installUpdate(for: update).value
        logger.notice("Agents update finished for \(update.rawValue, privacy: .public)")
      }
      try? await Task.sleep(for: .milliseconds(500))
      if let ready = defaults.string(forKey: "agentsReadyFile"), ready.hasPrefix("/") {
        FileManager.default.createFile(atPath: ready, contents: Data())
      }
      logger.notice("Agents settings shown")
    }

    /// The launch argument's short names; `NSAppearance.Name` raw values are `NSAppearanceName…`.
    private static func appearance(_ name: String) -> NSAppearance.Name? {
      switch name {
      case "aqua": .aqua
      case "darkAqua": .darkAqua
      default: nil
      }
    }

    private static func mainWindow(_ model: AppModel) async -> NSWindow? {
      for _ in 0..<100 {
        if let window = NSApplication.shared.windows.first(where: {
          $0.isVisible && $0.canBecomeMain && $0.frame.width >= 600
        }) {
          return window
        }
        if let opener = model.windowOpener { opener(id: "main") }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return nil
    }
  }
#endif
