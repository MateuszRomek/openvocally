/// Phrases a decoder looped on: the same words said twice in a row.
public enum RepeatedPhrase {
  /// The length in words of the longest run of 3 or more words that is followed immediately by
  /// itself, or 0. Words compare as `WordErrorRate.words` normalizes them.
  public static func longestRun(in text: String) -> Int {
    let words = WordErrorRate.words(text)
    for length in stride(from: words.count / 2, through: 3, by: -1) {
      for start in 0...(words.count - 2 * length)
      where words[start..<start + length] == words[start + length..<start + 2 * length] {
        return length
      }
    }
    return 0
  }
}
