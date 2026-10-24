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
    let size = library.state(of: model).downloadSize?.formatted(.byteCount(style: .file))
    let frees = "\(size.map { "This frees \($0). " } ?? "")You can download it again later."
    guard model == library.active, let replacement = library.replacement(for: model) else { return frees }
    return "\(replacement.name) becomes the active model. \(frees)"
  }

  private func delete(_ model: ModelID) {
    Task {
      do throws(RemoveError) {
        try await library.remove(model)
      } catch {
        refusal = error.message(for: model)
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

  private var current: ModelState { library.state(of: model) }
  private var isInstalled: Bool { current.readiness == .installed }
  private var isActive: Bool { current.isActive }

  var body: some View {
    LabeledContent {
      HStack(spacing: Space.s.points) {
        trailing.transition(.opacity)
        if current.isOnDisk, current.files != nil { actions.transition(.opacity) }
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
    .contextMenu { if current.isOnDisk { menuItems } }
  }

  /// The languages, then the download size or who installs it.
  private var facts: [String] {
    let current = current
    return [
      "\(current.languageCount) languages",
      current.downloadSize?.formatted(.byteCount(style: .file)) ?? "Installed by macOS",
    ]
  }

  /// Only the active row is tagged, with the runtime's state once it is on disk.
  private var activeTag: Tag? {
    guard isActive, isInstalled else { return nil }
    switch library.runtime {
    case .loading: return Tag("Loading", systemImage: "hourglass")
    case .failed: return Tag("Active", systemImage: "xmark.circle.fill", tint: .destructive)
    case .ready, .notInstalled: return Tag("Active", systemImage: "checkmark.circle.fill", tint: .success)
    }
  }

  private var problem: String? {
    let current = current
    if let failure = current.failure { return failure.message(downloadSize: current.downloadSize) }
    guard current.isActive, current.readiness == .installed, library.runtime == .failed else { return nil }
    return current.recovery.loadFailure
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
    switch current.readiness {
    case .installing: .downloading
    case .checking: .none
    case .installed where isActive:
      if library.runtime == .failed { .recover } else { .none }
    case .installed: .use
    case .notInstalled: .download
    }
  }

  @ViewBuilder private var trailing: some View {
    let current = current
    switch state {
    case .downloading:
      if case .installing(let progress) = current.readiness {
        DownloadProgressView(progress: progress, cancel: library.cancelInstall)
      }
    case .recover:
      Button(current.recovery.title) { Task { await library.recover(model) } }
        .appButton(.primary)
        .disabled(current.installBlocker == .anotherInstall)
    case .none:
      EmptyView()
    case .use:
      Button("Use") { library.select(model) }
        .appButton()
    case .download:
      Button(current.failure == nil ? "Download" : "Try Again") { library.install(model) }
        .appButton(isActive ? .primary : .secondary)
        .disabled(current.installBlocker != nil)
        .help(current.installBlocker?.help ?? "")
    }
  }

  @ViewBuilder private var languages: some View {
    if current.language != nil { LanguageControl(library: library, model: model) }
  }

  /// Only files OpenVocally downloaded can be shown or deleted; macOS manages its own.
  @ViewBuilder private var menuItems: some View {
    let current = current
    if let files = current.files {
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([files])
      }
      Divider()
      Button("Delete…", role: .destructive, action: delete).disabled(!current.canRemove)
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

extension InstallBlocker {
  fileprivate var help: String {
    switch self {
    case .anotherInstall: "Another model is downloading. Finish or cancel it first."
    case .needsLanguage: "Choose a language first."
    }
  }
}

extension RemoveError {
  fileprivate func message(for model: ModelID) -> String {
    switch self {
    case .noReplacement: "\(model.name) is the only model you can dictate with. Download another model first."
    case .installing: "\(model.name) is downloading. Cancel the download first."
    case .notRemovable, .fileSystem:
      "OpenVocally couldn't remove the model files. Try again, or delete them in Finder."
    }
  }
}

private struct DownloadProgressView: View {
  let progress: DownloadProgress
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: Space.s.points) {
      if let fraction = progress.fraction {
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
        Text(progress == .verifying ? "Verifying" : "Downloading")
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
    if case .installing = state(of: active).readiness { return .progress }
    switch runtime {
    case .ready: return .ok
    case .loading: return .progress
    case .notInstalled: return .attention
    case .failed: return .failed
    }
  }

  var statusDetail: String {
    let active = state(of: active)
    if case .installing(let progress) = active.readiness {
      if let fraction = progress.fraction {
        return "Downloading, \(fraction.formatted(.percent.precision(.fractionLength(0))))"
      }
      return progress == .verifying ? "Checking the download" : "Downloading"
    }
    switch runtime {
    case .ready: return "Ready to dictate"
    case .loading: return "Loading"
    case .notInstalled: return "Not downloaded yet. Download it below to start dictating."
    case .failed: return active.recovery.loadFailure
    }
  }
}

extension Recovery {
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

extension InstallError {
  func message(downloadSize: Int64?) -> String {
    switch self {
    case .download(let error): error.message(downloadSize: downloadSize)
    case .system(let error): error.message
    }
  }
}

extension DownloadError {
  fileprivate func message(downloadSize: Int64?) -> String {
    switch self {
    case .busy: "Another model is downloading. Finish or cancel it first."
    case .cancelled: "The download was cancelled."
    case .offline: "Couldn't reach Hugging Face. Check your connection and try again."
    case .server(let status): "Hugging Face answered with error \(status). Try again later."
    case .corrupted: "The download didn't match the published files, so nothing was installed. Try again."
    case .diskFull:
      if let size = downloadSize?.formatted(.byteCount(style: .file)) {
        "Not enough disk space. Free up \(size) and try again."
      } else {
        "Not enough disk space. Free up some space and try again."
      }
    case .fileSystem: "Couldn't save the model files. Try again."
    }
  }
}
