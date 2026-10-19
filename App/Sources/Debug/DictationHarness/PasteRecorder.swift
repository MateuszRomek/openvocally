#if DEBUG
  import DictationCore
  import Paste
  import Synchronization

  /// Takes the place of the paste: keeps the text and reports a paste at the moment it arrived,
  /// without touching the clipboard or posting a key.
  final class PasteRecorder: Sendable {
    struct Paste {
      let text: String
      let at: HostTime
    }

    private let last = Mutex<Paste?>(nil)

    func paste(_ transcript: Transcript) -> PasteOutcome {
      let now = HostTime.now()
      last.withLock { $0 = Paste(text: transcript.text, at: now) }
      return .pasted(target: nil, at: now)
    }

    /// The paste since the last call, if any.
    func take() -> Paste? {
      last.withLock { last in
        defer { last = nil }
        return last
      }
    }
  }
#endif
