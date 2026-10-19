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
      ForEach(Engine.allCases, id: \.self) { engine in
        Section {
          ForEach(engine.models) { model in
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
    let size = model.manifest.totalBytes.formatted(.byteCount(style: .file))
    let frees = "This frees \(size). You can download it again later."
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
        if isInstalled { actions.transition(.opacity) }
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
          ForEach(model.facts, id: \.self) { Tag($0) }
        }
        .motion(.confirm, value: ActiveBadge(shown: activeTag != nil, runtime: library.runtime))
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
    return "Couldn't load. Download it again, or OpenVocally tries again on your next dictation."
  }

  /// What the row's trailing control shows. Changes between states crossfade, so a finished
  /// download or a new active model doesn't snap.
  private enum Trailing: Equatable {
    case downloading
    case downloadAgain
    case none
    case use
    case download
  }

  private var state: Trailing {
    if download != nil { return .downloading }
    if isActive, isInstalled { return library.runtime == .failed ? .downloadAgain : .none }
    return isInstalled ? .use : .download
  }

  @ViewBuilder private var trailing: some View {
    switch state {
    case .downloading:
      if let download { DownloadProgressView(download: download, cancel: library.cancelDownload) }
    case .downloadAgain:
      Button("Download Again") { library.redownload(model) }
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
        .disabled(library.download != nil)
        .help(library.download != nil ? "Another model is downloading. Finish or cancel it first." : "")
    }
  }

  /// The active model can go only when another installed model takes over.
  private var canDelete: Bool {
    download == nil && (!isActive || library.replacement(for: model) != nil)
  }

  @ViewBuilder private var menuItems: some View {
    Button("Show in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([library.location(of: model)])
    }
    Divider()
    Button("Delete…", role: .destructive, action: delete).disabled(!canDelete)
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
    let size = manifest.totalBytes.formatted(.byteCount(style: .file))
    switch self {
    case .parakeetV3, .parakeetUltra: return ["25 languages", size]
    case .whisperTurbo: return ["99 languages", size]
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
        Text("Verifying").textStyle(.callout).foregroundStyle(.secondary)
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
      return download.fraction.map { "Downloading, \($0.formatted(.percent.precision(.fractionLength(0))))" }
        ?? "Checking the download"
    }
    switch runtime {
    case .ready: return "Ready to dictate"
    case .loading: return "Loading"
    case .notInstalled: return "Not downloaded yet. Download it below to start dictating."
    case .failed:
      return "Couldn't load. Download it again, or OpenVocally tries again on your next dictation."
    }
  }
}

extension DownloadError {
  func message(for model: ModelID) -> String {
    switch self {
    case .busy: "Another model is downloading. Finish or cancel it first."
    case .cancelled: "The download was cancelled."
    case .offline: "Couldn't reach Hugging Face. Check your connection and try again."
    case .server(let status): "Hugging Face answered with error \(status). Try again later."
    case .corrupted: "The download didn't match the published files, so nothing was installed. Try again."
    case .diskFull:
      "Not enough disk space. Free up \(model.manifest.totalBytes.formatted(.byteCount(style: .file))) and try again."
    case .fileSystem: "Couldn't save the model files. Try again."
    }
  }
}
