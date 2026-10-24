import DesignSystem
import Models
import SwiftUI
import Transcription

/// The language a system model transcribes, on its own line under the row's tags, with a
/// pop-up button that opens a searchable list of every language the model supports.
struct LanguageControl: View {
  let library: ModelLibrary
  let model: ModelID

  var body: some View {
    let language = library.state(of: model).language
    LanguagePicker(languages: language?.supported ?? [], chosen: language?.chosen) { locale in
      Task { await library.chooseLanguage(locale, for: model) }
    }
    .disabled(language?.canChange == false)
  }
}

/// A "Language" label and a pop-up button showing the chosen language.
struct LanguagePicker: View {
  let languages: [Locale]
  let chosen: Locale?
  let choose: (Locale) -> Void
  @State private var choosing = false

  var body: some View {
    HStack(spacing: Space.s.points) {
      Text("Language").textStyle(.callout).foregroundStyle(.secondary)
      Button {
        choosing = true
      } label: {
        HStack(spacing: Space.xs.points) {
          Text(title)
          Image(systemName: "chevron.up.chevron.down").imageScale(.small)
        }
      }
      .appButton(size: .small)
      .accessibilityLabel("Language, \(title)")
      .popover(isPresented: $choosing, arrowEdge: .bottom) {
        LanguagePopover(languages: languages, chosen: chosen) { locale in
          choosing = false
          choose(locale)
        }
        .frame(width: 300, height: 360)
      }
    }
  }

  private var title: String { chosen.map(Self.name) ?? "Choose…" }

  static func name(of locale: Locale) -> String {
    Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
  }
}

/// The popover's content: a search field over the languages, suggested ones first.
struct LanguagePopover: View {
  let languages: [Locale]
  let chosen: Locale?
  let choose: (Locale) -> Void
  @State private var query = ""
  @FocusState private var searching: Bool

  private var list: LanguageList {
    LanguageList(
      languages: languages, preferred: Locale.preferredLanguages, region: ModelLibrary.region, query: query,
      name: LanguagePicker.name)
  }

  var body: some View {
    let list = list
    VStack(spacing: 0) {
      TextField("Search", text: $query, prompt: Text("Search languages"))
        .textFieldStyle(.roundedBorder)
        .focused($searching)
        .onSubmit { if let submitted = list.submitted { choose(submitted) } }
        .padding(Space.s)
      Divider()
      if list.isEmpty {
        Text("No languages match")
          .textStyle(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          if list.suggested.isEmpty {
            rows(list.others)
          } else {
            Section("Suggested") { rows(list.suggested) }
            Section("All Languages") { rows(list.others) }
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
    }
    .onAppear { searching = true }
  }

  private func rows(_ locales: [Locale]) -> some View {
    ForEach(locales, id: \.identifier) { locale in
      Button {
        choose(locale)
      } label: {
        HStack {
          Text(LanguagePicker.name(of: locale))
          Spacer()
          if locale == chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)  // allowed: the List draws the row, so the button adds no chrome
      .accessibilityAddTraits(locale == chosen ? .isSelected : [])
    }
  }
}

extension SystemInstallError {
  var message: String {
    switch self {
    case .cancelled: "The download was cancelled."
    case .offline: "Couldn't reach Apple. Check your connection and try again."
    case .failed: "macOS couldn't install the speech files. Try again later."
    case .unavailable: "This Mac can't run Apple's speech models."
    case .diskFull: "Not enough disk space. Free up some space and try again."
    case .reservationLimit:
      "macOS keeps speech files for only a few languages per app. Choose a language the other Apple model uses, or try again later."
    }
  }
}
