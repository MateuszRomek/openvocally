import Testing

@testable import DictationCore

private enum Failure: Error, Equatable {
  case failed
}

struct DeadlineTests {
  @Test func `a fast body returns its value before the deadline`() async {
    let clock = ContinuousClock()
    let start = clock.now
    let value = await withDeadline(.seconds(30)) { 7 }
    #expect(value == 7)
    #expect(clock.now - start < .seconds(2))
  }

  @Test func `a body error passes through`() async {
    await #expect(throws: Failure.failed) {
      try await withDeadline(.seconds(30)) { () throws(Failure) -> Int in throw .failed }
    }
  }

  @Test func `a body that ignores cancellation still returns nil at the deadline`() async {
    let clock = ContinuousClock()
    let start = clock.now
    let value = await withDeadline(.milliseconds(50)) { () -> Int in
      await Task.detached { try? await Task.sleep(for: .seconds(10)) }.value
      return 1
    }
    #expect(value == nil)
    #expect(clock.now - start < .seconds(2))
  }

  @Test func `the body is cancelled at the deadline`() async {
    let (cancelled, report) = AsyncStream<Bool>.makeStream()
    let value: Void? = await withDeadline(.milliseconds(50)) {
      try? await Task.sleep(for: .seconds(30))
      report.yield(Task.isCancelled)
    }
    #expect(value == nil)
    var reports = cancelled.makeAsyncIterator()
    #expect(await reports.next() == true)
  }

  @Test func `a cancelled caller still waits for the body`() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let caller = Task {
      await withDeadline(.seconds(30)) { () -> Bool in
        for await _ in gate { break }
        return Task.isCancelled
      }
    }
    caller.cancel()
    open.yield()
    #expect(await caller.value == false)
  }
}
