#if DEBUG
  /// The last line of the harness output, as JSON.
  struct DictationHarnessSummary: Encodable {
    let summary = true
    /// The model the runs used, or nil when the scenario stopped before one was chosen.
    let model: String?
    let runs: Int
    let withText: Int
    let matched: Int
    /// Why no run was played although nothing failed, such as a model that isn't installed.
    let skipped: String?
    /// Why the harness stopped before playing every run.
    let failure: String?
  }
#endif
