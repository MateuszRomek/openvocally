import DictationCore
import Foundation
import Synchronization

@testable import Paste

final class FakePasteboard: Pasteboard {
  struct Write: Equatable {
    let items: [PasteboardItemSnapshot]
    let currentHostOnly: Bool
  }

  private struct State {
    var items: [PasteboardItemSnapshot]
    var changeCount = 1
    var writes: [Write] = []
  }

  private let state: Mutex<State>

  init(items: [PasteboardItemSnapshot]) {
    state = Mutex(State(items: items))
  }

  var items: [PasteboardItemSnapshot] { state.withLock { $0.items } }
  var writes: [Write] { state.withLock { $0.writes } }
  var changeCount: Int { state.withLock { $0.changeCount } }

  func readItems() -> [PasteboardItemSnapshot] { items }

  func replace(with items: [PasteboardItemSnapshot], currentHostOnly: Bool) -> Int {
    state.withLock {
      $0.items = items
      $0.changeCount += 1
      $0.writes.append(Write(items: items, currentHostOnly: currentHostOnly))
      return $0.changeCount
    }
  }

  func userCopies(_ text: String) {
    state.withLock {
      $0.items = [item((PasteboardMarker.plainText, text))]
      $0.changeCount += 1
    }
  }
}

final class FakeKeystroke: PasteKeystroke {
  private let results: Mutex<[Bool]>
  private let posted = Mutex(0)

  init(results: [Bool]) {
    self.results = Mutex(results)
  }

  var attempts: Int { posted.withLock { $0 } }

  func postCommandV() async -> HostTime? {
    posted.withLock { $0 += 1 }
    let succeeded = results.withLock { $0.isEmpty ? true : $0.removeFirst() }
    return succeeded ? HostTime(ticks: 42) : nil
  }
}

final class SleepLog: Sendable {
  private let durations = Mutex<[Duration]>([])
  var recorded: [Duration] { durations.withLock { $0 } }

  func sleep(_ duration: Duration) async {
    durations.withLock { $0.append(duration) }
    if duration > .milliseconds(300) { try? await Task.sleep(for: .seconds(3600)) }
  }

  func instant(_ duration: Duration) async {
    durations.withLock { $0.append(duration) }
  }
}

func item(_ representations: (String, String)...) -> PasteboardItemSnapshot {
  PasteboardItemSnapshot(
    representations: representations.map { PasteboardRepresentation(type: $0.0, data: Data($0.1.utf8)) })
}
