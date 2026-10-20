import Foundation

/// The languages a language picker lists for a search: the user's preferred languages first,
/// then the rest by name.
public struct LanguageList: Equatable, Sendable {
  public var suggested: [Locale]
  public var others: [Locale]

  /// Whether a search narrows the list. Without one, Return has no match to pick.
  let isSearching: Bool

  public var isEmpty: Bool { suggested.isEmpty && others.isEmpty }
  public var first: Locale? { suggested.first ?? others.first }
  /// What Return picks: the first match of a search, and nothing without one.
  public var submitted: Locale? { isSearching ? first : nil }

  /// `region` is the one a model's first language takes, so the first suggestion is that language.
  public init(
    languages: [Locale], preferred: [String], region: Locale.Region?, query: String,
    name: (Locale) -> String
  ) {
    var suggested: [Locale] = []
    for identifier in preferred {
      if let match = LocaleChoice.initial(supported: languages, preferred: [identifier], region: region),
        !suggested.contains(match)
      {
        suggested.append(match)
      }
    }
    let needle = query.trimmingCharacters(in: .whitespaces)
    isSearching = !needle.isEmpty
    func matches(_ locale: Locale) -> Bool {
      guard !needle.isEmpty else { return true }
      let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
      return name(locale).range(of: needle, options: options) != nil
        || locale.identifier.range(of: needle, options: options) != nil
    }
    self.suggested = suggested.filter(matches)
    self.others = languages.filter { !suggested.contains($0) && matches($0) }
      .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
  }
}
