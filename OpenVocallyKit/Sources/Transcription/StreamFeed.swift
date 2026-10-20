/// What a stream has been given of a growing recording, and what the release still owes it.
struct StreamFeed {
  private(set) var fed = 0
  private var last: [Float] = []

  /// The samples recorded since the previous call, or nil when there are none.
  mutating func next(_ recording: [Float]) -> ArraySlice<Float>? {
    guard recording.count > fed else { return nil }
    let suffix = recording[fed...]
    fed = recording.count
    last = recording
    return suffix
  }

  /// The samples of `final` the stream has not had, or nil when `final` doesn't start with what
  /// it had, so the stream heard a different recording.
  func rest(of final: [Float]) -> ArraySlice<Float>? {
    guard final.count >= fed, final[..<fed] == last[..<fed] else { return nil }
    return final[fed...]
  }
}
