#if FEATURE_AGENTS
  import Darwin
  import Dispatch
  import Foundation
  import Synchronization

  struct ProbeResult: Sendable, Equatable {
    enum Ending: Sendable, Equatable {
      case exited(Int32)
      case signaled(Int32)
      case timedOut
      /// The `posix_spawn` error number.
      case couldNotStart(Int32)
    }

    let ending: Ending
    /// Each capped by the run's `OutputWindow`, decoded as lossy UTF-8.
    let stdout: String
    let stderr: String
  }

  /// Which part of a long output to keep. Probes keep the head; an update keeps the tail, where npm
  /// and brew print the error.
  enum OutputWindow: Sendable, Equatable {
    case head(Int)
    case tail(Int)
  }

  /// The only place in Agents that starts a process; `scripts/check-banned-apis.sh` holds that.
  ///
  /// Never a shell and never a PATH lookup: argv is `[executable] + arguments` exactly. The child gets
  /// its own process group, so a timeout also kills what it started; without that a `#!/bin/sh`
  /// script running `sleep` keeps the pipe open and the probe never ends. `POSIX_SPAWN_CLOEXEC_DEFAULT`
  /// keeps every app descriptor out of the child, stdin is /dev/null and the working directory is /.
  enum Subprocess {
    static let outputCap = 64 * 1024
    /// Between SIGTERM and SIGKILL.
    static let killGrace: Duration = .milliseconds(300)
    /// How long a child that exited may keep its pipes open (through something it started) before
    /// its group is killed and the output so far is taken.
    static let drainGrace: Duration = .milliseconds(100)
    static let reapPoll: Duration = .milliseconds(25)

    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// A CLI, or the login shell, must not act with the app's Accessibility and Microphone grants.
    /// Private API, so it is looked up rather than linked, and a missing symbol only costs that.
    static let setDisclaim: SetDisclaim? = {
      guard
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
      else {
        agentsLogger.notice("Probes run without disclaiming responsibility: the symbol is unavailable")
        return nil
      }
      return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    /// Exit and output are observed with dispatch sources and reaped with `WNOHANG`, so no thread of
    /// the cooperative pool ever blocks on the child. Cancelling the calling task acts as a timeout.
    /// With `requireDisclaim`, the child never starts unless the disclaim call exists and succeeds:
    /// an update runs package scripts, which must not inherit the app's grants. A probe only runs
    /// `--version` and sign-in status, so it still starts when the symbol is missing.
    @concurrent
    static func run(
      _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration,
      output: OutputWindow = .head(outputCap), requireDisclaim: Bool = false
    ) async -> ProbeResult {
      let run: Run
      switch Run.spawn(
        executable, arguments, environment: environment, output: output, requireDisclaim: requireDisclaim)
      {
      case .failure(let error):
        agentsLogger.error("Could not start a probe: errno \(error.code, privacy: .public)")
        return ProbeResult(ending: .couldNotStart(error.code), stdout: "", stderr: "")
      case .success(let started):
        run = started
      }
      run.start(timeout: timeout)
      return await withTaskCancellationHandler {
        await withCheckedContinuation { run.deliver(to: $0) }
      } onCancel: {
        run.interrupt()
      }
    }
  }

  struct SpawnError: Error {
    let code: Int32
  }

  /// The group is only ever signalled while the leader is unreaped, exited or not: its PID, and so
  /// the process group ID, cannot be reused before `waitpid` releases it. Exit is detected with
  /// `WNOWAIT`, which leaves the zombie in place; the one `waitpid` happens in `settle`, after the
  /// last `kill`.
  private final class Run: Sendable {
    private struct State {
      var continuation: CheckedContinuation<ProbeResult, Never>?
      var result: ProbeResult?
      var stdout = Data()
      var stderr = Data()
      var openPipes = 2
      /// The leader exited and is a zombie that still holds the group.
      var exited = false
      var waitStatus: Int32?
      var interrupted = false
      var killGraceElapsed = false
      var drainScheduled = false
      var drainElapsed = false
      var reads: [any DispatchSourceRead] = []
      var exit: (any DispatchSourceProcess)?

      var reaped: Bool { waitStatus != nil }
    }

    private let pid: pid_t
    private let output: OutputWindow
    private let queue = DispatchQueue(label: "com.openvocally.agents.subprocess")
    private let state = Mutex(State())

    private init(pid: pid_t, output: OutputWindow) {
      self.pid = pid
      self.output = output
    }

    static func spawn(
      _ executable: URL, _ arguments: [String], environment: [String: String], output: OutputWindow,
      requireDisclaim: Bool
    ) -> Result<Run, SpawnError> {
      var out: [Int32] = [-1, -1]
      var err: [Int32] = [-1, -1]
      guard pipe(&out) == 0 else { return .failure(SpawnError(code: errno)) }
      guard pipe(&err) == 0 else {
        let code = errno
        close(out[0])
        close(out[1])
        return .failure(SpawnError(code: code))
      }
      // Another thread may spawn without CLOEXEC_DEFAULT; these must not leak into its child.
      for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

      var actions: posix_spawn_file_actions_t?
      posix_spawn_file_actions_init(&actions)
      defer { posix_spawn_file_actions_destroy(&actions) }
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      // A disclaimed child has no folder grants of its own, so an inherited cwd under ~/Desktop or
      // ~/Documents would be unreadable to it. "/" is also where a Finder-launched app already is.
      posix_spawn_file_actions_addchdir_np(&actions, "/")
      posix_spawn_file_actions_adddup2(&actions, out[1], 1)
      posix_spawn_file_actions_adddup2(&actions, err[1], 2)

      var attributes: posix_spawnattr_t?
      posix_spawnattr_init(&attributes)
      defer { posix_spawnattr_destroy(&attributes) }
      let flags =
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_SETSIGMASK
      posix_spawnattr_setflags(&attributes, Int16(flags))
      posix_spawnattr_setpgroup(&attributes, 0)
      // The app or a test runner may ignore SIGPIPE; a CLI expects the default.
      var defaults = sigset_t()
      sigemptyset(&defaults)
      sigaddset(&defaults, SIGPIPE)
      sigaddset(&defaults, SIGTERM)
      posix_spawnattr_setsigdefault(&attributes, &defaults)
      var mask = sigset_t()
      sigemptyset(&mask)
      posix_spawnattr_setsigmask(&attributes, &mask)
      let disclaimed = Subprocess.setDisclaim.map { $0(&attributes, 1) == 0 } ?? false
      if requireDisclaim && !disclaimed {
        for fd in out + err { close(fd) }
        return .failure(SpawnError(code: ENOTSUP))
      }

      let path = executable.path(percentEncoded: false)
      let argv = ([path] + arguments).map { strdup($0) } + [nil]
      let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer {
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
      }
      var pid: pid_t = 0
      let code = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
      close(out[1])
      close(err[1])
      guard code == 0 else {
        close(out[0])
        close(err[0])
        return .failure(SpawnError(code: code))
      }
      let run = Run(pid: pid, output: output)
      run.watch(stdout: out[0], stderr: err[0])
      return .success(run)
    }

    private func watch(stdout: Int32, stderr: Int32) {
      let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
      exit.setEventHandler { [self] in detectExit() }
      var reads: [any DispatchSourceRead] = []
      for (fd, isStdout) in [(stdout, true), (stderr, false)] {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain(fd, isStdout: isStdout, source: source) }
        source.setCancelHandler { close(fd) }
        reads.append(source)
      }
      state.withLock {
        $0.exit = exit
        $0.reads = reads
      }
      exit.resume()
      for source in reads { source.resume() }
      poll()
    }

    /// The exit source is registered asynchronously, and a child that exits before the
    /// registration lands never raises it: 4 of 2,000 concurrent probes of /usr/bin/true waited
    /// out their timeout that way. So exit is also polled until the child is reaped, slowly once
    /// the result is settled and only the zombie is left.
    private func poll() {
      detectExit()
      let (reaped, settled) = state.withLock { ($0.reaped, $0.result != nil) }
      guard !reaped else { return }
      schedule(after: settled ? .seconds(1) : Subprocess.reapPoll) { $0.poll() }
    }

    func start(timeout: Duration) {
      schedule(after: timeout) { $0.interrupt() }
    }

    func deliver(to continuation: CheckedContinuation<ProbeResult, Never>) {
      let ready: ProbeResult? = state.withLock {
        guard let result = $0.result else {
          $0.continuation = continuation
          return nil
        }
        return result
      }
      if let ready { continuation.resume(returning: ready) }
    }

    /// SIGTERM to the whole group, SIGKILL after the grace. The probe ends as `.timedOut` once the
    /// leader is reaped, or after a further backstop if the kernel never lets it go.
    func interrupt() {
      let first = state.withLock { state -> Bool in
        guard state.result == nil, !state.interrupted, !state.reaped else { return false }
        state.interrupted = true
        kill(-pid, SIGTERM)
        return true
      }
      guard first else { return }
      schedule(after: Subprocess.killGrace) { run in
        run.settle { state in
          state.killGraceElapsed = true
          if !state.reaped { kill(-run.pid, SIGKILL) }
        }
      }
      schedule(after: Subprocess.killGrace + .seconds(1)) { run in
        run.settle { state in
          guard state.result == nil else { return }
          run.complete(.timedOut, &state)
        }
      }
    }

    private func drain(_ fd: Int32, isStdout: Bool, source: any DispatchSourceRead) {
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
          let chunk = buffer[..<count]
          state.withLock { state in
            if isStdout {
              Self.keep(chunk, in: &state.stdout, output)
            } else {
              Self.keep(chunk, in: &state.stderr, output)
            }
          }
          continue
        }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        source.cancel()
        settle { $0.openPipes -= 1 }
        return
      }
    }

    private static func keep(_ chunk: ArraySlice<UInt8>, in data: inout Data, _ window: OutputWindow) {
      switch window {
      case .head(let cap):
        let room = cap - data.count
        if room > 0 { data.append(contentsOf: chunk.prefix(room)) }
      case .tail(let cap):
        data.append(contentsOf: chunk.suffix(cap))
        if data.count > cap { data = Data(data.suffix(cap)) }
      }
    }

    private func detectExit() {
      settle { state in
        guard !state.exited else { return }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid
        else { return }
        state.exited = true
        state.exit?.cancel()
        state.exit = nil
      }
    }

    /// Applies `change`, then does whatever the state now calls for, all under the lock so a kill
    /// can never land after the reap. Resumes the caller at most once.
    private func settle(_ change: (inout State) -> Void) {
      let delivery = state.withLock { state -> (CheckedContinuation<ProbeResult, Never>, ProbeResult)? in
        change(&state)
        if state.exited, !state.reaped {
          if state.interrupted {
            if state.killGraceElapsed {
              kill(-pid, SIGKILL)
              _ = reap(&state)
              complete(.timedOut, &state)
            }
          } else if state.openPipes == 0 {
            if reap(&state) { complete(ending(state), &state) }
          } else if state.drainElapsed {
            kill(-pid, SIGKILL)
            if reap(&state) { complete(ending(state), &state) }
          } else if !state.drainScheduled {
            state.drainScheduled = true
            schedule(after: Subprocess.drainGrace) { run in run.settle { $0.drainElapsed = true } }
          }
        }
        guard let result = state.result, let continuation = state.continuation else { return nil }
        state.continuation = nil
        return (continuation, result)
      }
      if let (continuation, result) = delivery { continuation.resume(returning: result) }
    }

    private func reap(_ state: inout State) -> Bool {
      var status: Int32 = 0
      guard waitpid(pid, &status, WNOHANG) == pid else { return false }
      state.waitStatus = status
      return true
    }

    private func complete(_ ending: ProbeResult.Ending, _ state: inout State) {
      guard state.result == nil else { return }
      state.result = ProbeResult(
        ending: ending, stdout: String(decoding: state.stdout, as: UTF8.self),
        stderr: String(decoding: state.stderr, as: UTF8.self))
      for source in state.reads { source.cancel() }
      state.reads = []
    }

    private func ending(_ state: State) -> ProbeResult.Ending {
      let status = state.waitStatus ?? 0
      let signal = status & 0x7f
      return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    /// Each scheduled step checks the state itself, so nothing needs cancelling.
    private func schedule(after delay: Duration, _ work: @escaping @Sendable (Run) -> Void) {
      let (seconds, attoseconds) = delay.components
      let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
      queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [self] in work(self) }
    }
  }
#endif
