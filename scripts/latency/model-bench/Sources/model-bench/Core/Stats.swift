import Foundation

/// Nearest-rank percentile: the smallest value with at least `percent` of the values at or below it.
func percentile(_ percent: Int, of values: [Double]) -> Double? {
  guard !values.isEmpty else { return nil }
  let sorted = values.sorted()
  let rank = (percent * sorted.count + 99) / 100
  return sorted[min(max(rank, 1), sorted.count) - 1]
}

/// Lowercased words with punctuation dropped. Apostrophes are removed inside words ("I'm" -> "im"),
/// every other non-letter, non-digit character separates words.
func normalizedWords(_ text: String) -> [String] {
  var cleaned = ""
  for scalar in text.lowercased().unicodeScalars {
    if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
      cleaned.unicodeScalars.append(scalar)
    } else if scalar == "'" || scalar == "\u{2019}" {
      continue
    } else {
      cleaned.append(" ")
    }
  }
  return cleaned.split(separator: " ").map(String.init)
}

/// Word error rate: word-level edit distance over the reference length.
func wordErrorRate(reference: String, hypothesis: String) -> Double {
  let ref = normalizedWords(reference)
  let hyp = normalizedWords(hypothesis)
  guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
  var previous = Array(0...hyp.count)
  var current = [Int](repeating: 0, count: hyp.count + 1)
  for i in 1...ref.count {
    current[0] = i
    for j in stride(from: 1, through: hyp.count, by: 1) {
      let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
      current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
    }
    swap(&previous, &current)
  }
  return Double(previous[hyp.count]) / Double(ref.count)
}
