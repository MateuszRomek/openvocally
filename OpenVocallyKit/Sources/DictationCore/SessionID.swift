/// Identifies one run from press to terminal display. Every completion carries it.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
  let raw: UInt64

  public var description: String { "session-\(raw)" }
}

#if DEBUG
  extension SessionID {
    /// A session no machine started, for harnesses that save synthetic dictations.
    public static func synthetic(_ raw: UInt64) -> SessionID { SessionID(raw: raw) }
  }
#endif
