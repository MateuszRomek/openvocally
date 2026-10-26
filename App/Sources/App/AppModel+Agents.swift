#if FEATURE_AGENTS
  import Agents

  extension AppModel {
    /// Opens Settings at the first provider with an update. Opening counts as seen, per version.
    func openAgentUpdate(_ notice: AgentUpdateNotice) {
      screen = .settings
      settingsAnchor = AgentsSections.sectionID(notice.firstKind)
      agents.dismiss(notice)
    }

    /// Starts the first health check. Returns true when the Debug harness took over the launch.
    func agentsDidLaunch() async -> Bool {
      agents.refresh(.launch)
      guard AgentsHarness.isRequested else { return false }
      await AgentsHarness.run(self)
      return true
    }

    /// Re-checks on return to the app, throttled per provider by the service. Returns at once.
    func agentsDidActivate() {
      agents.refresh(.appActivated)
    }
  }
#endif
