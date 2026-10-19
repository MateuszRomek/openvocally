public struct Recording: Sendable {
  /// 16 kHz mono Float32 from the press to the release.
  public let samples: [Float]
  /// First kept sample minus the press. Zero when the mic was warm, nil when nothing was kept.
  public let firstSampleOffset: Duration?
  /// Length of the kept audio, press (or first sample) to release.
  public let keptDuration: Duration
}
