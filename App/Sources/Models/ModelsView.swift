import AppKit
import DesignSystem
import Models
import SwiftUI
import Transcription

/// Every model grouped by engine. The active one carries an Active tag, so its state
/// lives in its own row instead of a separate card.
struct ModelsView: View {
  let library: ModelLibrary
  @State private var deleting: ModelID?
  @State private var refusal: String?

  var body: some View {
    Form {
      ForEach(library.engines, id: \.self) { engine in
        Section {
          ForEach(library.models(of: engine)) { model in
            ModelRow(library: library, model: model, delete: { deleting = model })
          }
        } header: {
          Text(engine.name)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Models")
    .confirmationDialog(
      deleting.map { "Delete \($0.name)?" } ?? "", isPresented: isDeleting, presenting: deleting
    ) { model in
      Button("Delete", role: .destructive) { delete(model) }
    } message: { model in
      Text(deleteMessage(model))
    }
    .alert(
      "Couldn't delete the model", isPresented: isRefused, presenting: refusal,
      actions: { _ in Button("OK") {} }, message: { Text($0) })
  }

  private var isDeleting: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  private var isRefused: Binding<Bool> {
    Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
  }

  private func deleteMessage(_ model: ModelID) -> String {
    let size = model.downloadable?.manifest.totalBytes.formatted(.byteCount(style: .file))
    let frees = "\(size.map { "This frees \($0). " } ?? "")You can download it again later."
    guard model == library.active, let replacement = library.replacement(for: model) else { return frees }
    return "\(replacement.name) becomes the active model. \(frees)"
  }

  private func delete(_ model: ModelID) {
    Task {
      do throws(ModelLibrary.DeleteError) {
        try await library.delete(model)
      } catch .noReplacement {
        refusal = "\(model.name) is the only model you can dictate with. Download another model first."
      } catch .downloading {
        refusal = "\(model.name) is downloading. Cancel the download first."
      } catch {
        refusal = "OpenVocally couldn't remove the model files. Try again, or delete them in Finder."
      }
    }
  }
}

private struct ModelRow: View {
  let library: ModelLibrary
  let model: ModelID
  let delete: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// What the Active tag animates on: appearing on the model just picked, and Loading turning
  /// into Active in place.
  private struct ActiveBadge: Equatable {
    let shown: Bool
    let runtime: RuntimeState
  }

  private var isInstalled: Bool { library.installed.contains(model) }
  private var isActive: Bool { model == library.active }
  private var download: ModelLibrary.Download? {
    library.download.flatMap { $0.model == model ? $0 : nil }
  }

  var body: some View {
    LabeledContent {
      HStack(spacing: Space.s.points) {
        trailing.transition(.opacity)
        if isInstalled, model.downloadable != nil { actions.transition(.opacity) }
      }
      .motion(.windowReveal, value: state)
    } label: {
      VStack(alignment: .leading, spacing: Space.s.points) {
        VStack(alignment: .leading, spacing: Space.xs.points) {
          Text(model.name).textStyle(.body).fontWeight(.medium)
          Text(model.summary)
            .textStyle(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: Space.xs.points) {
          if let activeTag { activeTag.transition(Motion.confirmEntrance(reduceMotion: reduceMotion)) }
          ForEach(facts, id: \.self) { Tag($0) }
        }
        .motion(.confirm, value: ActiveBadge(shown: activeTag != nil, runtime: library.runtime))
        languages
        if let problem {
          Label {
            Text(problem).textStyle(.callout).foregroundStyle(.secondary)
          } icon: {
            StatusIcon(.attention)
          }
          .labelStyle(.titleAndIcon)
          .transition(.opacity)
        }
      }
      .motion(.windowUnfold, value: problem)
      .motion(.windowReveal, value: library.runtime)
    }
    .contextMenu { if isInstalled { menuItems } }
  }

  private var facts: [String] {
    if case .system = model.source {
      return ["\(library.languages(of: model).count) languages", "Installed by macOS"]
    }
    return model.facts
  }

  /// Only the active row is tagged, with the runtime's state once it is on disk.
  private var activeTag: Tag? {
    guard isActive, isInstalled, download == nil else { return nil }
    switch library.runtime {
    case .loading: return Tag("Loading", systemImage: "hourglass")
    case .failed: return Tag("Active", systemImage: "xmark.circle.fill", tint: .destructive)
    case .ready, .notInstalled: return Tag("Active", systemImage: "checkmark.circle.fill", tint: .success)
    }
  }

  private var problem: String? {
    if let failure = library.failures[model] { return failure.message(for: model) }
    guard isActive, isInstalled, download == nil, library.runtime == .failed else { return nil }
    return library.recovery(for: model).loadFailure
  }

  /// What the row's trailing control shows. Changes between states crossfade, so a finished
  /// download or a new active model doesn't snap.
  private enum Trailing: Equatable {
    case downloading
    case recover
    case none
    case use
    case download
  }

  private var state: Trailing {
    if download != nil { return .downloading }
    if isActive, isInstalled { return library.runtime == .failed ? .recover : .none }
    return isInstalled ? .use : .download
  }

  @ViewBuilder private var trailing: some View {
    switch state {
    case .downloading:
      if let download { DownloadProgressView(download: download, cancel: library.cancelDownload) }
    case .recover:
      Button(library.recovery(for: model).title) { Task { await library.recover(model) } }
        .appButton(.primary)
        .disabled(library.download != nil)
    case .none:
      EmptyView()
    case .use:
      Button("Use") { library.select(model) }
        .appButton()
    case .download:
      Button(library.failures[model] == nil ? "Download" : "Try Again") { library.startDownload(model) }
        .appButton(isActive ? .primary : .secondary)
        .disabled(library.download != nil || needsLanguage)
        .help(downloadHelp)
    }
  }

  private var downloadHelp: String {
    if library.download != nil { return "Another model is downloading. Finish or cancel it first." }
    return needsLanguage ? "Choose a language first." : ""
  }

  /// A system model downloads one language, so it waits until there is one.
  private var needsLanguage: Bool {
    if case .system = model.source { return library.locale(of: model) == nil }
    return false
  }

  @ViewBuilder private var languages: some View {
    if case .system = model.source { LanguageControl(library: library, model: model) }
  }

  /// The active model can go only when another installed model takes over.
  private var canDelete: Bool {
    download == nil && (!isActive || library.replacement(for: model) != nil)
  }

  /// Only files OpenVocally downloaded can be shown or deleted; macOS manages its own.
  @ViewBuilder private var menuItems: some View {
    if let location = library.location(of: model) {
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([location])
      }
      Divider()
      Button("Delete…", role: .destructive, action: delete).disabled(!canDelete)
    }
  }

  private var actions: some View {
    Menu {
      menuItems
    } label: {
      Image(systemName: "ellipsis.circle").imageScale(.large).foregroundStyle(.secondary)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .appButton(.quiet)
    .fixedSize()
    .accessibilityLabel("More for \(model.name)")
  }
}

extension ModelID {
  /// Facts shown as tags under the summary: languages where the model card states them, then
  /// the download size.
  fileprivate var facts: [String] {
    switch source {
    case .huggingFace(let manifest):
      let size = manifest.totalBytes.formatted(.byteCount(style: .file))
      return [engine == .whisper ? "99 languages" : "25 languages", size]
    case .system: return []
    }
  }
}

private struct DownloadProgressView: View {
  let download: ModelLibrary.Download
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: Space.s.points) {
      if let fraction = download.fraction {
        ProgressView(value: fraction)
          .frame(width: 96)
          .accessibilityLabel("Downloading")
        Text(fraction, format: .percent.precision(.fractionLength(0)))
          .textStyle(.callout)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 32, alignment: .trailing)
      } else {
        ProgressView().controlSize(.small)
        Text(download.progress == .verifying ? "Verifying" : "Downloading")
          .textStyle(.callout)
          .foregroundStyle(.secondary)
      }
      Button("Cancel", action: cancel).appButton()
    }
  }
}

extension ModelLibrary {
  /// No model can dictate yet: none is installed, or the active one failed to load.
  var needsModel: Bool {
    runtime == .notInstalled || runtime == .failed
  }

  /// The active model's state, shared by the Models screen and the Settings checklist.
  var status: Status {
    if download?.model == active { return .progress }
    switch runtime {
    case .ready: return .ok
    case .loading: return .progress
    case .notInstalled: return .attention
    case .failed: return .failed
    }
  }

  var statusDetail: String {
    if let download, download.model == active {
      if let fraction = download.fraction {
        return "Downloading, \(fraction.formatted(.percent.precision(.fractionLength(0))))"
      }
      return download.progress == .verifying ? "Checking the download" : "Downloading"
    }
    switch runtime {
    case .ready: return "Ready to dictate"
    case .loading: return "Loading"
    case .notInstalled: return "Not downloaded yet. Download it below to start dictating."
    case .failed: return recovery(for: active).loadFailure
    }
  }
}

extension ModelLibrary.Recovery {
  var title: String {
    switch self {
    case .downloadAgain: "Download Again"
    case .tryAgain: "Try Again"
    }
  }

  var loadFailure: String {
    switch self {
    case .downloadAgain:
      "Couldn't load. Download it again, or OpenVocally tries again on your next dictation."
    case .tryAgain: "Couldn't load. Try again, or OpenVocally tries again on your next dictation."
    }
  }
}

extension DownloadError {
  func message(for model: ModelID) -> String {
    if case .system = model.source { return systemMessage }
    return switch self {
    case .busy: "Another model is downloading. Finish or cancel it first."
    case .cancelled: "The download was cancelled."
    case .offline: "Couldn't reach Hugging Face. Check your connection and try again."
    case .server(let status): "Hugging Face answered with error \(status). Try again later."
    case .corrupted: "The download didn't match the published files, so nothing was installed. Try again."
    case .diskFull:
      if let size = model.downloadable?.manifest.totalBytes.formatted(.byteCount(style: .file)) {
        "Not enough disk space. Free up \(size) and try again."
      } else {
        "Not enough disk space. Free up some space and try again."
      }
    case .fileSystem: "Couldn't save the model files. Try again."
    case .reservationLimit: systemMessage
    }
  }
}
