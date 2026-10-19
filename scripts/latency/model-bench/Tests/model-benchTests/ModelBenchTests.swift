import Testing

@testable import model_bench

@Test func werIgnoresCaseAndPunctuation() {
  #expect(wordErrorRate(reference: "Hello, world.", hypothesis: "hello world") == 0)
  #expect(wordErrorRate(reference: "I'm here", hypothesis: "Im here") == 0)
}

@Test func werCountsSubstitutionsInsertionsAndDeletions() {
  #expect(wordErrorRate(reference: "a b c d", hypothesis: "a x c") == 0.5)
  #expect(wordErrorRate(reference: "a b", hypothesis: "a b c d") == 1)
  #expect(wordErrorRate(reference: "a b", hypothesis: "") == 1)
}

@Test func normalizationKeepsPolishLetters() {
  #expect(
    normalizedWords("Przypomnij mi o dziesiątej, żeby") == ["przypomnij", "mi", "o", "dziesiątej", "żeby"])
}

@Test func percentileIsNearestRank() {
  let values = (1...20).map(Double.init)
  #expect(percentile(50, of: values) == 10)
  #expect(percentile(95, of: values) == 19)
  #expect(percentile(95, of: [5]) == 5)
  #expect(percentile(50, of: []) == nil)
}

@Test func tierFollowsP95() {
  #expect(tier(p95Ms: 249.9) == 1)
  #expect(tier(p95Ms: 250) == 2)
  #expect(tier(p95Ms: 499) == 2)
  #expect(tier(p95Ms: 500) == 3)
}

@Test func defaultOptions() throws {
  let options = try Options([])
  #expect(options.models == nil)
  #expect(options.strategies == nil)
  #expect(options.fixtures == .standard)
  #expect(options.runs == 20)
  #expect(options.effectiveLongRuns == 10)
  #expect(options.pace == .realtime)
  #expect(options.releaseGapMs == 0)
}

@Test func parsesListsAndAll() throws {
  let options = try Options([
    "--models", "parakeetV3,whisperTurbo", "--strategies", "all", "--fixtures", "all", "--runs", "5",
    "--pace", "instant", "--out", "/tmp/x", "--release-gap-ms", "400",
  ])
  #expect(options.models == ["parakeetV3", "whisperTurbo"])
  #expect(options.strategies == nil)
  #expect(options.fixtures == .all)
  #expect(options.effectiveLongRuns == 2)
  #expect(options.pace == .instant)
  #expect(options.out == "/tmp/x")
  #expect(options.releaseGapMs == 400)
  #expect(try Options(["--fixtures", "en-short"]).fixtures == .named(["en-short"]))
}

@Test func rejectsBadArguments() {
  #expect(throws: BenchError.self) { try Options(["--runs", "0"]) }
  #expect(throws: BenchError.self) { try Options(["--pace", "fast"]) }
  #expect(throws: BenchError.self) { try Options(["--models"]) }
  #expect(throws: BenchError.self) { try Options(["--bogus"]) }
}

@Test func emptyReferenceExpectsNoText() {
  #expect(wordErrorRate(reference: "", hypothesis: "") == 0)
  #expect(wordErrorRate(reference: "", hypothesis: "Thank you.") == 1)
}

@Test func repeatsFlagsOnlyRepetitionTheReferenceLacks() {
  var record = RunRecord(
    model: "m", strategy: "s", fixture: "f", pace: "instant", audioSeconds: 1, run: 1, releaseToTextMs: 0,
    appendBusyMs: 0, maxAppendLagMs: 0, fellBehind: false, thermal: "nominal", text: "", wer: nil, error: nil)
  record.score("one two three one two three", reference: "one two three")
  #expect(record.repeatedWords == 3)
  #expect(record.repeats)
  record.score("one two three one two three", reference: "one two three one two three")
  #expect(!record.repeats)
  record.score("one two one two", reference: "one two")
  #expect(record.repeatedWords == 0)
  #expect(!record.repeats)
}

@Test func catalogKeepsNoSpeechFixturesWithEmptyReferences() throws {
  let catalog = try fixtureCatalog()
  let references = Dictionary(catalog.map { ($0.id, $0.reference) }, uniquingKeysWith: { first, _ in first })
  #expect(references["silence"] == "")
  #expect(references["noise-3s"] == "")
  #expect(references["en-1s"]?.isEmpty == false)
  for id in defaultFixtures { #expect(references[id] != nil, "\(id) missing") }
}
