import Synchronization

/// Runs `body` until it returns or `limit` passes, whichever is first. Returns the body's value,
/// throws its error, or returns nil at the deadline.
///
/// The body runs in its own unstructured task, which is cancelled at the deadline but never
/// awaited after it, so a body that ignores cancellation or hangs cannot hold the caller; a task
/// group would wait for it. The caller's cancellation does not reach the body or end the wait, so
/// a call abandoned by a cancelled caller still finishes or times out on its own terms.
public func withDeadline<T: Sendable, Failure: Error>(
  _ limit: Duration, _ body: sending @escaping @isolated(any) () async throws(Failure) -> T
) async throws(Failure) -> T? {
  let first = FirstOutcome<Result<T, Failure>>()
  let work = Task {
    do throws(Failure) {
      first.settle(.success(try await body()))
    } catch {
      first.settle(.failure(error))
    }
  }
  let timer = Task {
    try? await Task.sleep(for: limit)
    first.settle(nil)
  }
  let outcome = await first.value()
  work.cancel()
  timer.cancel()
  return try outcome?.get()
}

/// Keeps the first outcome settled and drops the rest. Nil is the deadline's outcome.
private final class FirstOutcome<Value: Sendable>: Sendable {
  private enum State {
    case unsettled
    case awaited(CheckedContinuation<Value?, Never>)
    case settled(Value?)
  }

  private let state = Mutex(State.unsettled)

  func settle(_ outcome: Value?) {
    let waiter = state.withLock { state -> CheckedContinuation<Value?, Never>? in
      switch state {
      case .unsettled:
        state = .settled(outcome)
        return nil
      case .awaited(let waiter):
        state = .settled(outcome)
        return waiter
      case .settled:
        return nil
      }
    }
    waiter?.resume(returning: outcome)
  }

  /// Ignores cancellation: the timer bounds the wait.
  func value() async -> Value? {
    await withCheckedContinuation { waiter in
      let settled = state.withLock { state -> State in
        if case .unsettled = state { state = .awaited(waiter) }
        return state
      }
      if case .settled(let outcome) = settled { waiter.resume(returning: outcome) }
    }
  }
}
