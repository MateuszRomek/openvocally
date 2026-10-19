import DictationCore
import Synchronization
import Testing

@testable import Paste

struct PasterTests {
  private let previous = item(("public.utf8-plain-text", "before"))
  private let notes = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")

  private func paster(
    _ board: FakePasteboard, _ keys: FakeKeystroke, sleep: @escaping @Sendable (Duration) async -> Void,
    trusted: Bool = true, focus: FakeFocus = FakeFocus(.unknown)
  ) -> Paster {
    let notes = notes
    return Paster(
      pasteboard: board, keystroke: keys, isTrusted: { trusted }, frontmostApp: { notes },
      focusedField: { focus.field }, sleep: sleep)
  }

  private func hello() throws -> Transcript { try #require(Transcript("hello")) }

  @Test func `without Accessibility the clipboard is never touched`() async throws {
    let board = FakePasteboard(items: [previous])
    let keys = FakeKeystroke(results: [])
    let log = SleepLog()
    let outcome = await paster(board, keys, sleep: log.instant, trusted: false).paste(try hello())
    #expect(outcome == .failed(.accessibilityNotGranted))
    #expect(board.writes.isEmpty)
    #expect(keys.attempts == 0)
  }

  @Test func `a failed keystroke is retried once after 200 ms with a rewrite`() async throws {
    let board = FakePasteboard(items: [previous])
    let keys = FakeKeystroke(results: [false, true])
    let log = SleepLog()
    let outcome = await paster(board, keys, sleep: log.sleep).paste(try hello())
    guard case .pasted(let target, _) = outcome else {
      Issue.record("expected a paste, got \(outcome)")
      return
    }
    #expect(target == notes)
    #expect(keys.attempts == 2)
    #expect(board.writes.count == 2)
    #expect(log.recorded.first == .milliseconds(200))
  }

  @Test func `two failed keystrokes of a paste-last restore at once and fail`() async throws {
    let board = FakePasteboard(items: [previous])
    let keys = FakeKeystroke(results: [false, false])
    let log = SleepLog()
    let outcome = await paster(board, keys, sleep: log.sleep).paste(try hello(), kind: .pasteLast)
    #expect(outcome == .failed(.keystrokeFailed))
    #expect(board.items == [previous])
    #expect(log.recorded == [.milliseconds(200)])
  }

  @Test func `a paste restores the clipboard 420 ms later`() async throws {
    let board = FakePasteboard(items: [previous])
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: [true]), sleep: log.instant)
    #expect(await paster.paste(try hello()) == .pasted(target: notes, at: HostTime(ticks: 42)))
    await paster.waitForPendingRestore()
    #expect(log.recorded == [.milliseconds(420)])
    #expect(board.items == [previous])
  }

  @Test func `a new paste completes the pending restore first`() async throws {
    let board = FakePasteboard(items: [previous])
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.sleep)
    _ = await paster.paste(try hello())
    #expect(board.items != [previous])
    _ = await paster.paste(try #require(Transcript("again")))
    #expect(board.writes.count == 3)
    #expect(board.writes[1].items == [previous])
    await paster.flushPendingRestore()
    #expect(board.items == [previous])
  }

  @Test func `quitting during the retry wait still restores the clipboard`() async throws {
    let board = FakePasteboard(items: [previous])
    let (waiting, waits) = AsyncStream<Void>.makeStream()
    let paster = paster(board, FakeKeystroke(results: [false, true])) { _ in
      waits.yield()
      try? await Task.sleep(for: .seconds(3600))
    }
    let transcript = try hello()
    let pasting = Task { await paster.paste(transcript) }
    var iterator = waiting.makeAsyncIterator()
    await iterator.next()
    await paster.flushPendingRestore()
    #expect(board.items == [previous])
    pasting.cancel()
    #expect(await pasting.value == .failed(.keystrokeFailed))
  }

  @Test func `two failed keystrokes of a dictation leave the transcript for a manual paste`() async throws {
    let board = FakePasteboard(items: [previous])
    let log = SleepLog()
    let outcome = await paster(board, FakeKeystroke(results: [false, false]), sleep: log.instant)
      .paste(try hello())
    #expect(outcome == .needsManualPaste)
    #expect(board.items == board.writes.first?.items)
  }

  @Test func `outside a text field a dictation waits for the user's paste without a keystroke`() async throws
  {
    let board = FakePasteboard(items: [previous])
    let keys = FakeKeystroke(results: [])
    let log = SleepLog()
    let paster = paster(board, keys, sleep: log.instant, focus: FakeFocus(.noTextField))
    #expect(await paster.paste(try hello()) == .needsManualPaste)
    #expect(keys.attempts == 0)
    #expect(board.items == board.writes.first?.items)
  }

  @Test func `outside a text field a paste-last still posts the keystroke`() async throws {
    let keys = FakeKeystroke(results: [])
    let log = SleepLog()
    let paster = paster(
      FakePasteboard(items: [previous]), keys, sleep: log.instant, focus: FakeFocus(.noTextField))
    #expect(
      await paster.paste(try hello(), kind: .pasteLast) == .pasted(target: notes, at: HostTime(ticks: 42)))
    #expect(keys.attempts == 1)
  }

  @Test func `the user's paste in a text field restores the clipboard 900 ms later`() async throws {
    let board = FakePasteboard(items: [previous])
    let focus = FakeFocus(.noTextField)
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.instant, focus: focus)
    _ = await paster.paste(try hello())
    focus.field = .unknown
    #expect(await paster.completeManualPaste() == .pasted(target: notes))
    await paster.waitForPendingRestore()
    #expect(log.recorded == [.milliseconds(900)])
    #expect(board.items == [previous])
  }

  @Test func `the user's paste outside a text field keeps the window open`() async throws {
    let board = FakePasteboard(items: [previous])
    let focus = FakeFocus(.noTextField)
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.instant, focus: focus)
    _ = await paster.paste(try hello())
    #expect(await paster.completeManualPaste() == .notInTextField)
    #expect(board.items == board.writes.first?.items)
    focus.field = .unknown
    #expect(await paster.completeManualPaste() == .pasted(target: notes))
  }

  @Test func `a copy during the window ends it and keeps the user's copy`() async throws {
    let board = FakePasteboard(items: [previous])
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.instant, focus: FakeFocus(.noTextField))
    _ = await paster.paste(try hello())
    board.userCopies("mine")
    #expect(await paster.completeManualPaste() == .ended)
    await paster.abandonManualPaste()
    #expect(board.items == [item((PasteboardMarker.plainText, "mine"))])
  }

  @Test func `abandoning the window restores the clipboard at once`() async throws {
    let board = FakePasteboard(items: [previous])
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.instant, focus: FakeFocus(.noTextField))
    _ = await paster.paste(try hello())
    await paster.abandonManualPaste()
    #expect(board.items == [previous])
    #expect(log.recorded.isEmpty)
    #expect(await paster.completeManualPaste() == .ended)
  }

  @Test func `abandoning after the user's paste keeps the scheduled restore`() async throws {
    let board = FakePasteboard(items: [previous])
    let focus = FakeFocus(.noTextField)
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.sleep, focus: focus)
    _ = await paster.paste(try hello())
    focus.field = .unknown
    _ = await paster.completeManualPaste()
    await paster.abandonManualPaste()
    #expect(board.items == board.writes.first?.items)
    await paster.flushPendingRestore()
    #expect(board.items == [previous])
  }

  @Test func `quitting during the window restores the clipboard`() async throws {
    let board = FakePasteboard(items: [previous])
    let log = SleepLog()
    let paster = paster(board, FakeKeystroke(results: []), sleep: log.instant, focus: FakeFocus(.noTextField))
    _ = await paster.paste(try hello())
    await paster.flushPendingRestore()
    #expect(board.items == [previous])
  }
}

final class FakeFocus: Sendable {
  private let state: Mutex<FocusedField>

  init(_ field: FocusedField) {
    state = Mutex(field)
  }

  var field: FocusedField {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }
}
