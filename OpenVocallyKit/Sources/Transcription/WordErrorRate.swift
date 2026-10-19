/// How far a transcript is from a reference text, counted in words.
public enum WordErrorRate {
  /// Lowercased words with every character that is not a letter or a digit dropped, so
  /// punctuation, apostrophes and capitals never count as errors.
  public static func words(_ text: String) -> [String] {
    text.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map { String($0.filter { $0.isLetter || $0.isNumber }) }
      .filter { !$0.isEmpty }
  }

  /// Substitutions, insertions and deletions per reference word. An empty reference scores 0
  /// against an empty hypothesis and 1 against anything else.
  public static func rate(reference: String, hypothesis: String) -> Double {
    let expected = words(reference)
    let heard = words(hypothesis)
    guard !expected.isEmpty else { return heard.isEmpty ? 0 : 1 }
    var previous = Array(0...heard.count)
    for (row, word) in expected.enumerated() {
      var current = [row + 1] + Array(repeating: 0, count: heard.count)
      for (column, candidate) in heard.enumerated() {
        let substitution = previous[column] + (word == candidate ? 0 : 1)
        current[column + 1] = min(substitution, previous[column + 1] + 1, current[column] + 1)
      }
      previous = current
    }
    return Double(previous[heard.count]) / Double(expected.count)
  }
}
