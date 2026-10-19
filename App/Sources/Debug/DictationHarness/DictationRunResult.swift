#if DEBUG
  import Foundation

  /// One line of the harness output, as JSON.
  struct DictationRunResult: Encodable {
    let run: Int
    let fixture: String
    let mode: String
    let text: String
    let expected: String?
    let wordErrorRate: Double?
    let match: Bool
    /// Press to the overlay showing the recording, as the harness saw it. The signpost report
    /// is the reference number.
    let lb01Ms: Double?
    /// Release to the recorded paste.
    let lb02Ms: Double?
    let failure: String?
  }
#endif
