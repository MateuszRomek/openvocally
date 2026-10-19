import Foundation

/// One row of `summary.tsv`: every successful timed run of one model, strategy and fixture.
struct SummaryRow: Sendable, Equatable {
  let model: String
  let strategy: String
  let fixture: String
  let audioSeconds: Double
  let runs: Int
  let failures: Int
  let medianMs: Double
  let p95Ms: Double
  let minMs: Double
  let maxMs: Double
  let meanWER: Double
  /// Successful runs whose text repeats a phrase the reference does not.
  var repeats = 0

  /// 1 when p95 is under 250 ms, 2 under 500 ms, else 3. Engine time only: the app's tail wait
  /// and paste come on top.
  var tier: Int { model_bench.tier(p95Ms: p95Ms) }
}

func tier(p95Ms: Double) -> Int {
  if p95Ms < 250 { return 1 }
  if p95Ms < 500 { return 2 }
  return 3
}

let tierNote =
  "tier: 1 = p95 < 250 ms, 2 = p95 < 500 ms, 3 = slower. Engine time only, from release (last "
  + "append returned) to text (finish returned); the app's tail wait and paste are not included."

/// Rows grouped by model, strategy and fixture, in input order. Failed runs count in `failures`
/// and are left out of the times.
func summarize(_ records: [RunRecord]) -> [SummaryRow] {
  var order: [String] = []
  var groups: [String: [RunRecord]] = [:]
  for record in records {
    let key = "\(record.model)\t\(record.strategy)\t\(record.fixture)"
    if groups[key] == nil { order.append(key) }
    groups[key, default: []].append(record)
  }
  return order.compactMap { key in
    guard let group = groups[key], let first = group.first else { return nil }
    let succeeded = group.filter { $0.error == nil }
    let times = succeeded.map(\.releaseToTextMs)
    let wers = succeeded.compactMap(\.wer)
    return SummaryRow(
      model: first.model, strategy: first.strategy, fixture: first.fixture,
      audioSeconds: first.audioSeconds, runs: group.count, failures: group.count - succeeded.count,
      medianMs: percentile(50, of: times) ?? .nan, p95Ms: percentile(95, of: times) ?? .nan,
      minMs: times.min() ?? .nan, maxMs: times.max() ?? .nan,
      meanWER: wers.isEmpty ? .nan : wers.reduce(0, +) / Double(wers.count),
      repeats: succeeded.count(where: \.repeats))
  }
}

/// `summary.tsv`. The header is the documented format; add columns at the end, never rename them.
func summaryTSV(_ rows: [SummaryRow]) -> String {
  let header =
    "model\tstrategy\tfixture\taudio_s\tn\tmedian_ms\tp95_ms\tmin_ms\tmax_ms\tmean_wer\ttier\trepeats"
  let lines = rows.map { row in
    [
      row.model, row.strategy, row.fixture, format(row.audioSeconds, 2), "\(row.runs - row.failures)",
      format(row.medianMs, 1), format(row.p95Ms, 1), format(row.minMs, 1), format(row.maxMs, 1),
      format(row.meanWER, 4), "\(row.tier)", "\(row.repeats)",
    ].joined(separator: "\t")
  }
  return ([header] + lines).joined(separator: "\n") + "\n"
}

/// The console table, with failures shown.
func summaryTable(_ rows: [SummaryRow]) -> String {
  var lines = [
    "model         strategy      fixture     audio_s   n fail  median    p95    min    max  mean_wer tier repeats"
  ]
  for row in rows {
    lines.append(
      pad(row.model, 13) + " " + pad(row.strategy, 13) + " " + pad(row.fixture, 10)
        + String(
          format: " %7.1f %3d %4d %7.0f %6.0f %6.0f %6.0f %9.3f %4d %7d", row.audioSeconds,
          row.runs - row.failures, row.failures, row.medianMs, row.p95Ms, row.minMs, row.maxMs,
          row.meanWER, row.tier, row.repeats))
  }
  return lines.joined(separator: "\n")
}

private func format(_ value: Double, _ digits: Int) -> String {
  value.isNaN ? "" : String(format: "%.\(digits)f", value)
}

private func pad(_ text: String, _ width: Int) -> String {
  text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}
