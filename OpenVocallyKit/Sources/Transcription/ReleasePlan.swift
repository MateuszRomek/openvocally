/// The engine inputs the release decodes for a recording, in order.
struct ReleasePlan: Equatable {
  /// Pieces that closed at a cut and hold speech. Their samples can no longer change.
  var pieces: [Range<Int>]
  /// After the last cut, up to the trimmed end. Nil when it holds no speech.
  var tail: Range<Int>?
  /// The recording ended in a pause, so the tail is what the release would send if the user
  /// said nothing more.
  var tailIsSettled: Bool

  /// Every input the release needs, in order.
  var inputs: [Range<Int>] { pieces + (tail.map { [$0] } ?? []) }
}

/// Plans a growing recording. The pieces depend only on the samples, never on how often or in
/// what steps the recording was fed, because every cut decision reads only the frames it has
/// seen, in order.
struct ReleasePlanner {
  private let lookahead: Lookahead
  private var cutter: PieceCutter?

  init(_ lookahead: Lookahead) {
    self.lookahead = lookahead
    if case .pieces(let shortest, let longest) = lookahead {
      cutter = PieceCutter(shortest: shortest, longest: longest)
    }
  }

  /// Plans finished samples from scratch, so an early call counts only when it decoded exactly
  /// what the release sends.
  static func plan(finished samples: [Float], _ lookahead: Lookahead) -> ReleasePlan {
    var planner = ReleasePlanner(lookahead)
    return planner.plan(samples)
  }

  /// `recording` must extend the samples of the previous call.
  mutating func plan(_ recording: [Float]) -> ReleasePlan {
    let end = TrailingQuiet.trimmed(recording).count
    let settled = end < recording.count
    switch lookahead {
    case .off:
      preconditionFailure("The runtime never plans a recording without a lookahead")
    case .wholeRecording:
      return ReleasePlan(pieces: [], tail: 0..<end, tailIsSettled: settled)
    case .pieces:
      guard var cutter else { preconditionFailure("A pieces lookahead has a cutter") }
      cutter.consume(recording)
      self.cutter = cutter
      let starts = [0] + cutter.cuts
      // A quiet piece or tail would only invite a hallucinated "Thank you."
      let pieces = zip(starts, cutter.cuts).map { $0..<$1 }.filter(cutter.holdsSpeech)
      let start = cutter.cuts.last ?? 0
      let tail = end > start && cutter.holdsSpeech(start..<end) ? start..<end : nil
      return ReleasePlan(pieces: pieces, tail: tail, tailIsSettled: settled)
    }
  }
}

/// The cut policy, private so nothing else can cut differently.
private struct PieceCutter {
  static let frame = 320
  /// 300 ms of frames under `quietRatio` of the peak, or quiet outright, is a pause.
  static let pauseFrames = 15
  static let quietRatio: Float = 0.12
  /// The peak is the loudest 100 ms average, so a click a frame long cannot make the speech
  /// around it look like a pause.
  static let peakFrames = 5
  /// A forced cut picks the quietest frame among the last 2 s.
  static let forcedSearchFrames = 100

  let shortest: Int
  let longest: Int
  private(set) var cuts: [Int] = []
  /// RMS per 20 ms frame, from the first sample.
  private var levels: [Float] = []
  private var peak: Float = 0
  private var quietRun = 0

  init(shortest: Int, longest: Int) {
    self.shortest = shortest
    self.longest = longest
  }

  /// Reads the whole frames of `samples` it has not read yet.
  mutating func consume(_ samples: [Float]) {
    let frame = Self.frame
    for index in levels.count..<samples.count / frame {
      let end = (index + 1) * frame
      let level = Self.rms(samples[end - frame..<end])
      levels.append(level)
      let recent = levels[max(0, index - Self.peakFrames + 1)...]
      peak = max(peak, recent.reduce(0, +) / Float(Self.peakFrames))
      let start = cuts.last ?? 0
      if level < max(peak * Self.quietRatio, TrailingQuiet.quietRMS) {
        quietRun += 1
      } else {
        // Cut once speech resumes, in the middle of the pause, so neither piece clips a word and
        // a pause the recording ends in stays one input with the speech before it.
        let cut = end - frame - quietRun * frame / 2
        if quietRun >= Self.pauseFrames, cut - start >= shortest { cuts.append(cut) }
        quietRun = 0
      }
      if end - (cuts.last ?? 0) >= longest {
        let first = (max(start, end - Self.forcedSearchFrames * frame) + frame - 1) / frame
        let quietest = (first...index).min { levels[$0] < levels[$1] } ?? index
        cuts.append((quietest + 1) * frame)
        quietRun = 0
      }
    }
  }

  /// Whether some frame in `range` is louder than quiet, so silence has nothing to decode. An
  /// absolute floor, so a loud click elsewhere cannot drop quieter speech.
  func holdsSpeech(_ range: Range<Int>) -> Bool {
    let first = range.lowerBound / Self.frame
    let last = min(levels.count, (range.upperBound + Self.frame - 1) / Self.frame)
    guard first < last else { return false }
    return levels[first..<last].contains { $0 >= TrailingQuiet.quietRMS }
  }

  private static func rms(_ frame: ArraySlice<Float>) -> Float {
    var energy: Float = 0
    for sample in frame { energy += sample * sample }
    return (energy / Float(frame.count)).squareRoot()
  }
}
