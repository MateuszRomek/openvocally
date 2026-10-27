import Darwin
import Foundation
import Testing

@testable import Agents

struct SubprocessTests {
  @Test func aHangingScriptIsKilledWithEverythingItStarted() async throws {
    let sandbox = try Sandbox()
    let leader = sandbox.url("leader")
    let child = sandbox.url("child")
    let stub = try sandbox.script(
      "hang.sh", "echo $$ > '\(leader.path)'\nsleep 600 &\necho $! > '\(child.path)'\nwait")
    let started = written(leader)

    let result = await Subprocess.run(stub, [], environment: [:], timeout: .seconds(2))

    #expect(result.ending == .timedOut)
    #expect(ContinuousClock.now - (await started.value) < .seconds(2) + Subprocess.killGrace + .seconds(1))
    let leaderPID = try pid(in: leader)
    let childPID = try pid(in: child)
    #expect(kill(leaderPID, 0) == -1 && errno == ESRCH, "the script was reaped")
    // The orphaned sleep is reaped by launchd, which can take a moment after SIGKILL.
    #expect(await gone(childPID), "the sleep it started was killed")
  }

  @Test func aGrandchildThatIgnoresTermIsKilledOnTimeout() async throws {
    let sandbox = try Sandbox()
    let grandchild = sandbox.url("grandchild")
    let stub = try sandbox.script(
      "hang.sh",
      """
      /bin/sh -c "trap '' TERM; echo \\$$ > '\(grandchild.path)'; exec sleep 60" > /dev/null 2>&1 &
      wait
      """)

    let result = await Subprocess.run(stub, [], environment: [:], timeout: .seconds(2))

    #expect(result.ending == .timedOut)
    #expect(await gone(try pid(in: grandchild)), "the grandchild that ignores SIGTERM was killed")
  }

  @Test func aChildThatExitsWhileAGrandchildHoldsStdoutEndsPromptly() async throws {
    let sandbox = try Sandbox()
    let grandchild = sandbox.url("grandchild")
    let stub = try sandbox.script(
      "exit.sh",
      """
      /bin/sh -c "echo \\$$ > '\(grandchild.path)'; exec sleep 60" &
      while [ ! -s '\(grandchild.path)' ]; do sleep 0.01; done
      echo done
      exit 0
      """)
    let exiting = written(grandchild)

    let result = await Subprocess.run(stub, [], environment: [:], timeout: .seconds(30))

    #expect(result.ending == .exited(0))
    #expect(result.stdout == "done\n")
    #expect(ContinuousClock.now - (await exiting.value) < Subprocess.drainGrace + .seconds(2))
    #expect(await gone(try pid(in: grandchild)), "the grandchild holding stdout was killed")
  }

  @Test func eachChildIsResponsibleForItselfNotForTheApp() async throws {
    #expect(Subprocess.setDisclaim != nil, "responsibility_spawnattrs_setdisclaim resolves on this macOS")
    typealias Responsible = @convention(c) (pid_t) -> pid_t
    let symbol = try #require(
      dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
    let responsible = unsafeBitCast(symbol, to: Responsible.self)
    let sandbox = try Sandbox()
    let marker = sandbox.url("pid")
    let stub = try sandbox.script("self.sh", "echo $$ > '\(marker.path)'\nsleep 600")
    let task = Task { await Subprocess.run(stub, [], environment: [:], timeout: .seconds(30)) }
    defer { task.cancel() }

    var child: pid_t?
    for _ in 0..<200 where child == nil {
      child = try? pid(in: marker)
      if child == nil { try await Task.sleep(for: .milliseconds(25)) }
    }
    let pid = try #require(child)

    #expect(responsible(pid) == pid)
    task.cancel()
    #expect(await task.value.ending == .timedOut)
  }

  @Test func manyQuickProbesAllReportTheirExit() async {
    let endings = await withTaskGroup(of: ProbeResult.Ending.self) { group in
      for _ in 0..<2000 {
        group.addTask {
          await Subprocess.run(
            URL(filePath: "/usr/bin/true"), [], environment: [:], timeout: .seconds(10)
          ).ending
        }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }

    let unexpected = endings.filter { $0 != .exited(0) }
    let counts = Dictionary(grouping: unexpected.map { "\($0)" }, by: { $0 }).mapValues(\.count)
    #expect(unexpected.isEmpty, "\(counts)")
  }

  @Test func cancellingTheCallerKillsTheChild() async throws {
    let sandbox = try Sandbox()
    let stub = try sandbox.script("hang.sh", "sleep 600")
    let task = Task { await Subprocess.run(stub, [], environment: [:], timeout: .seconds(60)) }
    try await Task.sleep(for: .milliseconds(200))
    let started = ContinuousClock.now
    task.cancel()

    #expect(await task.value.ending == .timedOut)
    #expect(ContinuousClock.now - started < Subprocess.killGrace + .seconds(1))
  }

  @Test func outputIsCappedAndArgvIsPassedAsIs() async throws {
    let sandbox = try Sandbox()
    let stub = try sandbox.script(
      "echo.sh", "printf '%s|' \"$@\" >&2\n/usr/bin/yes | /usr/bin/head -c 200000")

    let result = await Subprocess.run(stub, ["a b", "$HOME", ";"], environment: [:], timeout: .seconds(5))

    #expect(result.ending == .exited(0))
    #expect(result.stdout.utf8.count == Subprocess.outputCap)
    #expect(result.stderr == "a b|$HOME|;|")
  }

  @Test func aMissingExecutableCannotStart() async {
    let result = await Subprocess.run(
      URL(filePath: "/nonexistent/claude"), [], environment: [:], timeout: .seconds(1))
    #expect(result.ending == .couldNotStart(ENOENT))
  }

  @Test func loginEnvironmentIgnoresRcNoiseAndIsReadOnceUntilInvalidated() async throws {
    let sandbox = try Sandbox()
    let runs = sandbox.url("runs")
    let shell = try sandbox.script(
      "shell",
      """
      echo run >> '\(runs.path)'
      echo 'Welcome noise=1'
      printf 'prompt%% '
      /bin/sh -c "$4"
      echo 'trailing noise=2'
      """)
    let login = LoginEnvironment(shell: shell, timeout: .seconds(5), fallbackDirectories: [])

    let environment = await login.current()
    #expect(environment["OPENVOCALLY_RESOLVING_ENVIRONMENT"] == nil)
    #expect(environment["PATH"] != nil)
    #expect(!environment.keys.contains { $0.contains("noise") || $0.contains("prompt") })
    _ = await login.current()
    #expect(try String(contentsOf: runs, encoding: .utf8) == "run\n")

    login.invalidate()
    _ = await login.current()
    #expect(try String(contentsOf: runs, encoding: .utf8) == "run\nrun\n")
  }

  @Test func aLoginShellThatHangsFallsBackToAMinimalPath() async throws {
    let sandbox = try Sandbox()
    let shell = try sandbox.script("shell", "sleep 600")
    let login = LoginEnvironment(
      shell: shell, timeout: .milliseconds(300), fallbackDirectories: [URL(filePath: "/opt/homebrew/bin")])

    let environment = await login.current()

    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
  }

  @Test func theShellSeesTheResolvingMarkerButTheEnvironmentDoesNot() async throws {
    let sandbox = try Sandbox()
    let seen = sandbox.url("seen")
    let shell = try sandbox.script(
      "shell", "printf '%s' \"$OPENVOCALLY_RESOLVING_ENVIRONMENT\" > '\(seen.path)'\n/bin/sh -c \"$4\"")
    let login = LoginEnvironment(shell: shell, timeout: .seconds(5), fallbackDirectories: [])

    let environment = await login.current()

    #expect(try String(contentsOf: seen, encoding: .utf8) == "1")
    #expect(environment["PATH"] != nil)
    #expect(environment[LoginEnvironment.resolvingMarker] == nil)
  }

  @Test func aFailedReadIsNotCachedSoTheNextCheckRetries() async throws {
    let sandbox = try Sandbox()
    let runs = sandbox.url("runs")
    let healed = sandbox.url("healed")
    let shell = try sandbox.script(
      "shell",
      """
      echo run >> '\(runs.path)'
      [ -e '\(healed.path)' ] || exit 1
      /bin/sh -c "$4"
      """)
    let login = LoginEnvironment(
      shell: shell, timeout: .seconds(5), fallbackDirectories: [URL(filePath: "/opt/homebrew/bin")])

    let fallback = await login.current()
    #expect(fallback["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
    try Data().write(to: healed)
    let resolved = await login.current()
    #expect(resolved["PATH"] != fallback["PATH"])
    _ = await login.current()

    #expect(try String(contentsOf: runs, encoding: .utf8) == "run\nrun\n")
  }

  /// When `file` first holds something, or after 30 s. The timing tests start their clock there,
  /// at a line the script runs, so a slow start under a loaded parallel test run doesn't count
  /// against them.
  private func written(_ file: URL) -> Task<ContinuousClock.Instant, Never> {
    Task {
      for _ in 0..<6000 where (try? Data(contentsOf: file))?.isEmpty ?? true {
        try? await Task.sleep(for: .milliseconds(5))
      }
      return ContinuousClock.now
    }
  }

  private func pid(in file: URL) throws -> pid_t {
    try #require(
      pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func gone(_ pid: pid_t) async -> Bool {
    for _ in 0..<40 {
      if kill(pid, 0) == -1 && errno == ESRCH { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }
}
