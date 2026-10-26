#if FEATURE_AGENTS
  import Foundation
  import Observation

  /// Owns each provider's saved configuration, last health and update advisory, and is the only
  /// writer of `states`. Process and network work runs in `@concurrent` helpers and comes back as
  /// values, so no check blocks the main actor.
  @MainActor @Observable public final class AgentHealthService {
    public struct State: Sendable, Equatable {
      public let kind: AgentKind
      public var configuration: ProviderConfiguration
      public var health: ProviderHealth
      public var update: UpdateAdvisory
      /// The latest version known for this install, whatever the advisory says.
      var latest: CLIVersion?
      var updateRun: UpdateRun = .idle

      /// Nil when there is nothing to update or no command for it.
      public var updateOffer: UpdateOffer? {
        guard configuration.enabled, let installation = health.installation else { return nil }
        return UpdateOffer(installation: installation, kind: kind, latest: latest, run: updateRun)
      }

      /// A run with no offer to show it under, such as an update after which no working copy was
      /// found. Settings shows its line under the status.
      public var updateRunWithoutOffer: UpdateRun? {
        guard configuration.enabled, updateRun != .idle, updateOffer == nil else { return nil }
        return updateRun
      }
    }

    /// Everything the service tracks for one provider besides what it shows.
    private struct ProviderTracker {
      /// Bumped by every superseding check; a check whose generation is stale drops its result.
      var generation = 0
      var running: Task<Void, Never>?
      var lastLocalCheck: Date?
      /// Queued or running; nil otherwise.
      var update: Task<Void, Never>?
      /// A configuration change arrived during the update; replayed when it ends.
      var refreshAfterUpdate = false
    }

    public enum Reason: Sendable, Equatable {
      case launch
      /// Also drops the cached login-shell environment, so a PATH fix shows up. Throttled per
      /// provider like `appActivated`; otherwise supersedes a running check.
      case settingsShown
      /// Throttled per provider: switching apps must not spawn processes every time.
      case appActivated
      /// A session failed to start or died. Never throttled, and supersedes a running check.
      case sessionFailed
      /// Enable or chosen path. Supersedes a running check and shows `.checking`.
      case configurationChanged
    }

    static let seenUpdatesKey = "agentsSeenUpdates"

    /// Also bounds how often `settingsShown` drops the login-shell environment.
    static let activationThrottle: TimeInterval = 10

    private(set) var states: [AgentKind: State]

    public subscript(kind: AgentKind) -> State {
      states[kind]
        ?? State(kind: kind, configuration: ProviderConfiguration(), health: .disabled, update: .unknown)
    }

    /// The latest version per provider whose notice was opened or dismissed.
    private var seenUpdates: [AgentKind: CLIVersion]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: AgentEnvironment
    @ObservationIgnored private let loginEnvironment: LoginEnvironment
    @ObservationIgnored private var trackers: [AgentKind: ProviderTracker] = [:]
    @ObservationIgnored private var lastLoginInvalidation: Date?
    @ObservationIgnored private var lockTails: [UpdateLockKey: Task<Void, Never>] = [:]

    /// Starts nothing; the app refreshes once it has launched.
    public init(defaults: UserDefaults = .standard, environment: AgentEnvironment = .live()) {
      self.defaults = defaults
      self.environment = environment
      let known = AgentKind.allCases.flatMap { $0.spec.knownLocations(environment.home) }
      loginEnvironment = LoginEnvironment(
        timeout: environment.timeouts.loginShell,
        fallbackDirectories: known.map { $0.deletingLastPathComponent() })
      var states: [AgentKind: State] = [:]
      for kind in AgentKind.allCases {
        let configuration = ProviderConfiguration.load(kind, from: defaults)
        states[kind] = State(
          kind: kind, configuration: configuration, health: configuration.enabled ? .checking : .disabled,
          update: .unknown)
      }
      self.states = states
      let seen = defaults.dictionary(forKey: Self.seenUpdatesKey) as? [String: String] ?? [:]
      seenUpdates = Dictionary(
        uniqueKeysWithValues: seen.compactMap { key, value in
          guard let kind = AgentKind(rawValue: key), let version = CLIVersion(value) else { return nil }
          return (kind, version)
        })
    }

    public func setEnabled(_ enabled: Bool, for kind: AgentKind) {
      updateConfiguration(kind) { $0.enabled = enabled }
      clearFinishedRun(kind)
      refresh(.configurationChanged, kinds: [kind])
    }

    /// nil goes back to automatic detection.
    public func setChosenPath(_ path: URL?, for kind: AgentKind) {
      updateConfiguration(kind) { $0.chosenPath = path }
      clearFinishedRun(kind)
      refresh(.configurationChanged, kinds: [kind])
    }

    /// Does not re-check: arguments do not change health.
    public func setLaunchArguments(_ text: String, for kind: AgentKind) {
      updateConfiguration(kind) { $0.launchArguments = LaunchArguments(text) }
    }

    /// Runs the local check and then the update check for every enabled provider in `kinds`, and
    /// returns at once; await the task to wait for both. `launch` and `appActivated` join a running
    /// check; the other reasons cancel it and drop its result.
    @discardableResult
    public func refresh(_ reason: Reason, kinds: Set<AgentKind> = Set(AgentKind.allCases)) -> Task<
      Void, Never
    > {
      if reason == .settingsShown {
        let now = environment.now()
        if lastLoginInvalidation.map({ !Self.isWithinThrottle($0, now: now) }) ?? true {
          loginEnvironment.invalidate()
          lastLoginInvalidation = now
        }
      }
      var tasks: [Task<Void, Never>] = []
      for kind in AgentKind.allCases where kinds.contains(kind) {
        if let task = start(kind, reason) { tasks.append(task) }
      }
      return Task { for task in tasks { await task.value } }
    }

    /// The path to launch and the argument tail. Never a shell string.
    func launchCommand(for kind: AgentKind) throws(LaunchCommandError) -> LaunchCommand {
      let state = self[kind]
      guard state.configuration.enabled else { throw .disabled }
      guard trackers[kind]?.update == nil else { throw .updating }
      guard !state.health.blocksUse, let installation = state.health.installation else {
        throw .blocked(state.health.status)
      }
      do {
        return LaunchCommand(
          executable: installation.path, arguments: try state.configuration.launchArguments.split())
      } catch {
        throw .arguments(error)
      }
    }

    private func updateConfiguration(_ kind: AgentKind, _ change: (inout ProviderConfiguration) -> Void) {
      var state = self[kind]
      change(&state.configuration)
      state.configuration.save(kind, to: defaults)
      states[kind] = state
    }

    private func start(_ kind: AgentKind, _ reason: Reason) -> Task<Void, Never>? {
      let tracker = trackers[kind, default: ProviderTracker()]
      // A probe now would read a half-written install; the update re-checks when it ends.
      if let update = tracker.update {
        if reason == .configurationChanged {
          trackers[kind, default: ProviderTracker()].refreshAfterUpdate = true
        }
        return update
      }
      let state = self[kind]
      guard state.configuration.enabled else {
        supersede(kind)
        states[kind]?.health = .disabled
        states[kind]?.update = .unknown
        states[kind]?.latest = nil
        return nil
      }
      let now = environment.now()
      if reason == .launch || reason == .appActivated, let task = tracker.running { return task }
      if reason == .appActivated || reason == .settingsShown, let last = tracker.lastLocalCheck,
        Self.isWithinThrottle(last, now: now)
      {
        return tracker.running
      }
      if reason == .configurationChanged || state.health == .disabled {
        states[kind]?.health = .checking
        states[kind]?.update = .unknown
        states[kind]?.latest = nil
      }
      return check(kind)
    }

    /// Supersedes any running check and starts a fresh one; the last result stays on screen.
    private func check(_ kind: AgentKind) -> Task<Void, Never> {
      let generation = supersede(kind)
      trackers[kind, default: ProviderTracker()].lastLocalCheck = environment.now()
      let configuration = self[kind].configuration
      let task = Task { [environment, loginEnvironment] in
        let health = await HealthCheck.run(
          kind, configuration, environment, loginEnvironment: loginEnvironment)
        guard trackers[kind]?.generation == generation else { return }
        states[kind]?.health = health
        trackers[kind]?.running = nil
        agentsLogger.info(
          "\(kind.rawValue, privacy: .public) health: \(health.status.rawValue, privacy: .public)")
        let (update, latest) = await advisory(for: health, kind: kind)
        guard trackers[kind]?.generation == generation else { return }
        states[kind]?.update = update
        states[kind]?.latest = latest
      }
      trackers[kind, default: ProviderTracker()].running = task
      return task
    }

    private static func isWithinThrottle(_ last: Date, now: Date) -> Bool {
      now.timeIntervalSince(last) < activationThrottle
    }

    /// Cancels the running check, which kills its child, and returns the new generation.
    @discardableResult
    private func supersede(_ kind: AgentKind) -> Int {
      var tracker = trackers[kind, default: ProviderTracker()]
      tracker.running?.cancel()
      tracker.running = nil
      tracker.generation += 1
      trackers[kind] = tracker
      return tracker.generation
    }

    /// Reaches the network only when the cached answer for this source is stale. Runs on the main
    /// actor so two providers sharing a source never race on the cache blob.
    private func advisory(
      for health: ProviderHealth, kind: AgentKind
    ) async -> (UpdateAdvisory, latest: CLIVersion?) {
      guard let installation = health.installation,
        let source = installation.ownership.latestVersionSource(kind.spec)
      else { return (.unknown, nil) }
      let cache = LatestVersionCache(defaults: defaults)
      if !cache.entry(for: source).isFresh(now: environment.now()) {
        do {
          let version = try await environment.latestVersions(source)
          cache.update(source) { $0.lastFetched = .init(version: version.description, at: environment.now()) }
        } catch {
          if Task.isCancelled { return (.unknown, nil) }
          agentsLogger.notice("Latest version check failed for \(source.cacheKey, privacy: .public)")
          cache.update(source) { $0.lastFailureAt = environment.now() }
        }
      }
      let latest = cache.entry(for: source).version
      return (UpdateCheck.advisory(installed: installation.version, latest: latest), latest)
    }

    // MARK: Updates

    /// Runs the provider's own update command, then re-checks its health. Idempotent: while one is
    /// queued or running for `kind`, returns that task. Nothing cancels it: killing npm or brew
    /// halfway leaves a broken install. Only `Timeouts.update` ends a run that hangs.
    ///
    /// A configuration change during the run lets it finish, but its outcome is never computed
    /// against another install: when the provider was turned off or its chosen path changed, the
    /// run ends idle and the replayed refresh decides what shows.
    @discardableResult
    public func installUpdate(for kind: AgentKind) -> Task<Void, Never> {
      if let task = trackers[kind]?.update { return task }
      let state = self[kind]
      guard let offer = state.updateOffer, offer.canStart, let shown = state.health.installation,
        let recipe = UpdateRecipe(shown, spec: kind.spec)
      else { return Task {} }
      let configuration = state.configuration
      let previous = lockTails[recipe.lock]
      states[kind]?.updateRun = previous == nil ? .running : .queued
      supersede(kind)
      let task = Task { [environment, loginEnvironment] in
        await previous?.value
        guard isUnchanged(kind, since: configuration) else {
          return finishUpdate(kind, lock: recipe.lock, .idle)
        }
        states[kind]?.updateRun = .running
        let located = await HealthCheck.locate(
          kind, configuration, environment, loginEnvironment: loginEnvironment)
        guard isUnchanged(kind, since: configuration) else {
          return finishUpdate(kind, lock: recipe.lock, .idle)
        }
        guard let fresh = located.installation, CLIUpdate.isSameInstall(shown, fresh) else {
          return await fail(kind, lock: recipe.lock, .installationChanged)
        }
        let alreadyCurrent = offer.latest.map { fresh.version >= $0 } ?? false
        if !alreadyCurrent,
          let failure = await CLIUpdate.run(
            recipe, searchDirectories: located.searchDirectories, environment: located.probeEnvironment,
            timeout: environment.timeouts.update)
        {
          guard isUnchanged(kind, since: configuration) else {
            return finishUpdate(kind, lock: recipe.lock, .idle)
          }
          return await fail(kind, lock: recipe.lock, failure)
        }
        guard isUnchanged(kind, since: configuration) else {
          return finishUpdate(kind, lock: recipe.lock, .idle)
        }
        await check(kind).value
        guard isUnchanged(kind, since: configuration) else {
          return finishUpdate(kind, lock: recipe.lock, .idle)
        }
        let outcome: UpdateOutcome =
          if let now = self[kind].health.installation {
            now.version > shown.version ? .updated(to: now.version) : .stillOutdated(now.version)
          } else {
            .couldNotVerify
          }
        finishUpdate(kind, lock: recipe.lock, .finished(outcome))
      }
      trackers[kind, default: ProviderTracker()].update = task
      lockTails[recipe.lock] = task
      return task
    }

    /// Whether the provider is still on and still points at the same chosen path.
    private func isUnchanged(_ kind: AgentKind, since configuration: ProviderConfiguration) -> Bool {
      let now = self[kind].configuration
      return now.enabled && now.chosenPath == configuration.chosenPath
    }

    /// Ends the run as failed, then re-checks health so the row shows what is installed now and a
    /// stale install cannot fail the same way again.
    private func fail(_ kind: AgentKind, lock: UpdateLockKey, _ failure: UpdateFailure) async {
      let replays = trackers[kind]?.refreshAfterUpdate ?? false
      finishUpdate(kind, lock: lock, .failed(failure))
      if !replays, self[kind].configuration.enabled { await check(kind).value }
    }

    /// Replays a configuration change made during the run as a refresh.
    private func finishUpdate(_ kind: AgentKind, lock: UpdateLockKey, _ run: UpdateRun) {
      states[kind]?.updateRun = run
      var tracker = trackers[kind, default: ProviderTracker()]
      if lockTails[lock] == tracker.update { lockTails[lock] = nil }
      tracker.update = nil
      let replay = tracker.refreshAfterUpdate
      tracker.refreshAfterUpdate = false
      trackers[kind] = tracker
      // The run can carry the tool's last output line, which may name the user or their registry.
      agentsLogger.info(
        "\(kind.rawValue, privacy: .public) update: \(String(describing: run), privacy: .private)")
      if replay { refresh(.configurationChanged, kinds: [kind]) }
    }

    /// A configuration change clears an outcome from an install that may no longer be shown.
    private func clearFinishedRun(_ kind: AgentKind) {
      if states[kind]?.updateRun.isActive == false { states[kind]?.updateRun = .idle }
    }

    /// Every enabled provider with an update whose version was not opened or dismissed yet.
    public var updateNotice: AgentUpdateNotice? {
      AgentUpdateNotice(states: AgentKind.allCases.map { self[$0] }, seen: seenUpdates)
    }

    /// Remembers these providers at these versions; a newer version shows the notice again.
    public func dismiss(_ notice: AgentUpdateNotice) {
      for item in notice.updates { seenUpdates[item.kind] = item.latest }
      defaults.set(
        Dictionary(uniqueKeysWithValues: seenUpdates.map { ($0.key.rawValue, $0.value.description) }),
        forKey: Self.seenUpdatesKey)
    }
  }
#endif
