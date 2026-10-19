/// Drops the quiet after the user stopped talking, keeping a short pad.
///
/// Frames start at multiples of 20 ms from the first sample, so a recording so far that already
/// ends in more than the pad of quiet trims to exactly the samples the whole recording trims to,
/// unless the user speaks again.
enum TrailingQuiet {
  static let frame = 320
  /// 20 ms frames below this RMS count as quiet (about -50 dBFS).
  static let quietRMS: Float = 0.003
  /// Quiet kept after the last loud frame. 100 ms changed the text of `en-15s`; 200 to 500 ms
  /// left every model-bench fixture unchanged.
  static let pad = 4_800

  /// Up to `pad` after the last loud frame, or every sample when none is loud.
  static func trimmed(_ samples: [Float]) -> ArraySlice<Float> {
    var frameStart = (samples.count / frame - 1) * frame
    while frameStart >= 0 {
      if isLoud(samples[frameStart..<frameStart + frame]) {
        return samples[..<min(samples.count, frameStart + frame + pad)]
      }
      frameStart -= frame
    }
    return samples[...]
  }

  private static func isLoud(_ frame: ArraySlice<Float>) -> Bool {
    var energy: Float = 0
    for sample in frame { energy += sample * sample }
    return energy / Float(frame.count) >= quietRMS * quietRMS
  }
}
