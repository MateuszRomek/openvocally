import Synchronization

/// Time that moves only when the test moves it. A sleeper wakes when the clock passes its
/// deadline or when its task is cancelled, as `Task.sleep` does.
final class TestClock: Sendable {
  private struct Sleeper {
    let id: Int
    let deadline: Duration
    let waiter: CheckedContinuation<Void, Never>
  }

  private struct State {
    var elapsed = Duration.zero
    var nextID = 0
    var sleepers: [Sleeper] = []
    var watchers: [(until: @Sendable (Int) -> Bool, waiter: CheckedContinuation<Void, Never>)] = []

    mutating func readyWatchers() -> [CheckedContinuation<Void, Never>] {
      let count = sleepers.count
      let ready = watchers.filter { $0.until(count) }.map(\.waiter)
      watchers.removeAll { $0.until(count) }
      return ready
    }
  }

  private let origin = ContinuousClock.now
  private let state = Mutex(State())

  var now: ContinuousClock.Instant { origin + state.withLock { $0.elapsed } }

  func sleep(for duration: Duration) async {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiter in
        // Checked under the lock, so a cancel either finds this sleeper or is seen here.
        let (wakeNow, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
          guard !Task.isCancelled else { return (true, []) }
          state.sleepers.append(Sleeper(id: id, deadline: state.elapsed + duration, waiter: waiter))
          return (false, state.readyWatchers())
        }
        for watcher in ready { watcher.resume() }
        if wakeNow { waiter.resume() }
      }
    } onCancel: {
      let (sleeper, ready) = state.withLock { state -> (Sleeper?, [CheckedContinuation<Void, Never>]) in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return (nil, []) }
        return (state.sleepers.remove(at: index), state.readyWatchers())
      }
      sleeper?.waiter.resume()
      for watcher in ready { watcher.resume() }
    }
  }

  /// How many tasks sleep until at most `limit` from now.
  func sleepers(dueWithin limit: Duration) -> Int {
    state.withLock { state in state.sleepers.count { $0.deadline - state.elapsed <= limit } }
  }

  /// Returns once at least `count` tasks are asleep on this clock.
  func sleepers(atLeast count: Int) async {
    await sleepers { $0 >= count }
  }

  /// Returns once no task is asleep on this clock.
  func noSleepers() async {
    await sleepers { $0 == 0 }
  }

  private func sleepers(until condition: @escaping @Sendable (Int) -> Bool) async {
    await withCheckedContinuation { watcher in
      let now = state.withLock { state in
        let met = condition(state.sleepers.count)
        if !met { state.watchers.append((condition, watcher)) }
        return met
      }
      if now { watcher.resume() }
    }
  }

  /// Moves to the earliest deadline and wakes every sleeper due by then.
  func advanceToNextDeadline() {
    let wait = state.withLock { state in state.sleepers.map(\.deadline).min().map { $0 - state.elapsed } }
    if let wait { advance(by: wait) }
  }

  func advance(by duration: Duration) {
    let (due, ready) = state.withLock { state -> ([Sleeper], [CheckedContinuation<Void, Never>]) in
      state.elapsed += duration
      let elapsed = state.elapsed
      let due = state.sleepers.filter { $0.deadline <= elapsed }
      state.sleepers.removeAll { $0.deadline <= elapsed }
      return (due, state.readyWatchers())
    }
    for sleeper in due { sleeper.waiter.resume() }
    for watcher in ready { watcher.resume() }
  }
}
