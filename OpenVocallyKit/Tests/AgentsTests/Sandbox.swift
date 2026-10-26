import AgentFakes
import AgentFakesTestSupport
import Foundation
import Synchronization
import Testing

@testable import Agents

/// A temp directory, a throwaway defaults suite, a fixed clock and a counting fetch, all removed when
/// the test lets go of it.
final class Sandbox {
  let directory: URL
  let defaults: UserDefaults
  let clock = TestClock()
  let fetches = FetchCounter()
  private let suiteName = "agents-tests-\(UUID().uuidString)"

  init() throws {
    let created = FileManager.default.temporaryDirectory.appending(path: "agents-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    // Resolved paths come back through /private, so the expectations must start there too.
    directory = created.resolvingSymlinksInPath()
    defaults = try #require(UserDefaults(suiteName: suiteName))
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }

  func environment(
    directories: [URL] = [], timeouts: AgentEnvironment.Timeouts = .unhurried,
    latest: Result<CLIVersion, TestFetchError> = .success(CLIVersion(9, 9, 9))
  ) -> AgentEnvironment {
    let fetches = fetches
    let clock = clock
    return AgentEnvironment(
      home: directory,
      search: .only(directories: directories, environment: ProcessInfo.processInfo.environment),
      latestVersions: { _ in
        fetches.count.add(1, ordering: .relaxed)
        return try latest.get()
      },
      now: { clock.now },
      timeouts: timeouts)
  }

  @MainActor
  func service(
    directories: [URL] = [], timeouts: AgentEnvironment.Timeouts = .unhurried,
    latest: Result<CLIVersion, TestFetchError> = .success(CLIVersion(9, 9, 9))
  ) -> AgentHealthService {
    AgentHealthService(
      defaults: defaults,
      environment: environment(directories: directories, timeouts: timeouts, latest: latest))
  }

  func configure(_ kind: AgentKind, enabled: Bool = true, path: URL? = nil, arguments: String = "") {
    let configuration = ProviderConfiguration(
      enabled: enabled, chosenPath: path, launchArguments: LaunchArguments(arguments))
    configuration.save(kind, to: defaults)
  }

  /// An executable `#!/bin/sh` script at `relativePath` under the sandbox.
  @discardableResult
  func script(_ relativePath: String, _ body: String) throws -> URL {
    let url = directory.appending(path: relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  /// A script that hands everything to a fake, so a path outside the fakes' layout still answers
  /// as that persona.
  @discardableResult
  func forwarder(_ relativePath: String, to fake: URL) throws -> URL {
    try script(relativePath, "exec '\(fake.path(percentEncoded: false))' \"$@\"")
  }

  @discardableResult
  func symlink(_ relativePath: String, to destination: URL) throws -> URL {
    let url = directory.appending(path: relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    return url
  }

  func url(_ relativePath: String) -> URL { directory.appending(path: relativePath) }
}

final class TestClock: Sendable {
  private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
  var now: Date { value.withLock { $0 } }
  func advance(_ interval: TimeInterval) { value.withLock { $0 += interval } }
}

final class FetchCounter: Sendable {
  let count = Atomic(0)
  var value: Int { count.load(ordering: .relaxed) }
}

struct TestFetchError: Error {}

func fake(_ kind: AgentKind, _ scenario: ScenarioID) throws -> URL {
  try FakeAgents.shared().path(Provider(rawValue: kind.rawValue) ?? .claude, scenario)
}

@MainActor
/// Ticks on the main actor and keeps the longest gap between ticks. Code that held the main actor
/// through a probe leaves a gap as long as the probe; a busy machine only slows the ticks down.
final class Ticker {
  private(set) var longestGap: Duration = .zero
  private var task: Task<Void, Never>?

  func start() {
    task = Task { @MainActor [weak self] in
      var last = ContinuousClock.now
      while !Task.isCancelled {
        let now = ContinuousClock.now
        if let self { self.longestGap = max(self.longestGap, now - last) }
        last = now
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  func stop() { task?.cancel() }
}

extension AgentEnvironment.Timeouts {
  /// For tests that check what a probe answered, not how long it took, so a loaded machine
  /// running the whole suite in parallel never turns an answer into a timeout. The hang tests
  /// pass their own short timeouts.
  static let unhurried = Self(version: .seconds(60), signIn: .seconds(60), loginShell: .seconds(60))
}
