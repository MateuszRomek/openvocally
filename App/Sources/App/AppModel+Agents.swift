#if FEATURE_AGENTS
  import Agents
  import AppKit

  extension AppModel {
    /// Opens Settings at the first provider with an update. Opening counts as seen, per version.
    func openAgentUpdate(_ notice: AgentUpdateNotice) {
      screen = .settings
      settingsAnchor = AgentsSections.sectionID(notice.firstKind)
      agents.dismiss(notice)
    }

    /// Starts the first health check and the re-check on each return to the app. Returns true when
    /// the Debug harness took over the launch.
    func agentsDidLaunch() async -> Bool {
      agents.refresh(.launch)
      agentsActivationWatch = Task { [agents] in
        let activations = NotificationCenter.default.notifications(
          named: NSApplication.didBecomeActiveNotification)
        for await _ in activations {
          agents.refresh(.appActivated)
        }
      }
      guard AgentsHarness.isRequested else { return false }
      await AgentsHarness.run(self)
      return true
    }
  }
#endif
