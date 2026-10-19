/// How many transcripts one page loads. The model preloads the first page and the list grows by
/// the same step, so both read it here.
enum TranscriptPaging {
  static let pageSize = 30
}
