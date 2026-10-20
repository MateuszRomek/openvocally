import Foundation
import Testing

@testable import Transcription

struct LanguageListTests {
  private let languages = ["en_US", "en_GB", "pl_PL", "es_ES", "de_DE"].map(Locale.init(identifier:))
  private let names = [
    "en_US": "English (United States)", "en_GB": "English (United Kingdom)", "pl_PL": "Polish",
    "es_ES": "español (España)", "de_DE": "German",
  ]

  private func list(_ query: String, preferred: [String] = [], region: String? = nil) -> LanguageList {
    LanguageList(
      languages: languages, preferred: preferred, region: region.map { Locale.Region($0) }, query: query
    ) { names[$0.identifier]! }
  }

  private func ids(_ locales: [Locale]) -> [String] { locales.map(\.identifier) }

  @Test func `pol finds Polish`() {
    #expect(ids(list("pol").others) == ["pl_PL"])
  }

  @Test func `uppercase ENG finds every English`() {
    #expect(ids(list("ENG").others) == ["en_GB", "en_US"])
  }

  @Test func `espanol finds español`() {
    #expect(ids(list("espanol").others) == ["es_ES"])
  }

  @Test func `an identifier matches`() {
    #expect(ids(list("de_DE").others) == ["de_DE"])
  }

  @Test func `preferred languages come first, the rest by name`() {
    let all = list("", preferred: ["pl-PL", "en-US"])
    #expect(ids(all.suggested) == ["pl_PL", "en_US"])
    #expect(ids(all.others) == ["en_GB", "es_ES", "de_DE"])
    #expect(all.first?.identifier == "pl_PL")
  }

  @Test func `no match is empty`() {
    #expect(list("klingon").isEmpty)
  }

  @Test func `Return picks the first match of a search, and nothing without one`() {
    #expect(list("pol").submitted?.identifier == "pl_PL")
    #expect(list("", preferred: ["pl-PL"]).submitted == nil)
    #expect(list("   ", preferred: ["pl-PL"]).submitted == nil)
  }

  @Test func `the first suggestion is the language a model starts with`() {
    let region = Locale.Region("GB")
    let suggested = list("", preferred: ["en"], region: "GB").first
    #expect(suggested?.identifier == "en_GB")
    #expect(suggested == LocaleChoice.initial(supported: languages, preferred: ["en"], region: region))
  }
}
