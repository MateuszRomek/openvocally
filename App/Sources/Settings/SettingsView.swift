import AppKit
import AudioCapture
import DesignSystem
import Diagnostics
import Overlay
import SoundCues
import Storage
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  let model: AppModel

  var body: some View {
    Form {
      Section("Setup") {
        SetupRows(model: model)
        SettingRow("Welcome tour", subtitle: "Walk through setup again.") {
          Button("Show Again") { model.replayOnboarding() }.appButton(size: .small)
        }
      }
      Section("Shortcuts") { ShortcutsSection(shortcuts: model.shortcuts) }
      Section("Microphone") { MicrophonePicker(input: model.input) }
      Section("Sound feedback") { SoundFeedbackRows(play: model.previewSoundCue) }
      Section("Appearance") { AppearanceRows() }
      Section("History") { HistoryRows(history: model.history) }
      if model.updates.isAvailable {
        Section("Updates") { UpdatesRows(updates: model.updates) }
      }
      Section("Support") {
        DiagnosticsRow(model: model)
        if let policy = URL(string: "https://openvocally.com/privacy") {
          SettingRow("Privacy", subtitle: "What stays on your Mac and what goes online.") {
            Link("Privacy Policy", destination: policy)
          }
        }
        VersionRow()
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
  }
}

/// What dictation depends on, each with the button that fixes it. Once nothing needs
/// the user, the checklist folds into one row, with the details a click away.
private struct SetupRows: View {
  let model: AppModel
  @State private var showsDetails = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if isSetUp {
        LabeledContent {
          Button(showsDetails ? "Hide details" : "Show details") {
            withAnimation(Motion.windowUnfold.resolved(reduceMotion: reduceMotion)) {
              showsDetails.toggle()
            }
          }
          .appButton(.quiet, size: .small)
        } label: {
          StatusRow(title: summaryTitle, detail: summaryDetail, status: summaryStatus)
        }
        if showsDetails { checklist.padding(.leading, StatusRow.textInset) }
      } else {
        checklist
      }
    }
    .motion(.windowUnfold, value: isSetUp)
  }

  private var isSetUp: Bool {
    model.input.access == .granted && model.shortcuts.accessibilityGranted && !model.models.needsModel
  }

  private var isReady: Bool { model.models.status == .ok }

  private var summaryStatus: Status { isReady ? .ok : .progress }

  private var summaryTitle: String { isReady ? "Ready to dictate" : "Getting ready" }

  private var summaryDetail: String {
    isReady
      ? "The microphone, Accessibility and the speech model are all set."
      : "Loading the speech model."
  }

  @ViewBuilder private var checklist: some View {
    LabeledContent {
      if model.models.needsModel {
        Button("Open Models") { model.screen = .models }
          .appButton(size: .small)
      }
    } label: {
      StatusRow(title: "Speech model", detail: modelDetail, status: model.models.status)
    }
    LabeledContent {
      switch model.input.access {
      case .granted: EmptyView()
      case .notDetermined:
        Button("Allow") { Task { await model.input.requestAccess() } }
          .appButton(size: .small)
      case .denied:
        Button("Open System Settings") { PrivacyPane.microphone.open() }
          .appButton(size: .small)
      }
    } label: {
      StatusRow(title: "Microphone", detail: microphoneDetail, status: microphoneStatus)
    }
    LabeledContent {
      if !model.shortcuts.accessibilityGranted {
        Button("Open System Settings") { PrivacyPane.accessibility.open() }
          .appButton(size: .small)
      }
    } label: {
      StatusRow(
        title: "Accessibility",
        detail: model.shortcuts.accessibilityGranted
          ? "Allowed" : "Needed for the shortcuts and to paste into other apps",
        status: model.shortcuts.accessibilityGranted ? .ok : .attention)
    }
  }

  private var microphoneDetail: String {
    switch model.input.access {
    case .granted: "Allowed"
    case .notDetermined: "Needed to hear you"
    case .denied: "Turned off for OpenVocally in System Settings"
    }
  }

  private var microphoneStatus: Status {
    model.input.access == .granted ? .ok : .attention
  }

  private var modelDetail: String {
    let models = model.models
    return models.status == .ok ? "\(models.active.name) is ready" : models.statusDetail
  }
}

/// Nil is the system default, which follows the Mac's own input setting.
private struct MicrophonePicker: View {
  let input: AudioInput

  var body: some View {
    SettingRow("Input device", subtitle: helper) {
      Picker("Input device", selection: selection) {
        Text(systemDefaultTitle).tag(String?.none)
        ForEach(input.devices.devices) { microphone in
          Text(microphone.name).tag(Optional(microphone.uid))
        }
        if let uid = input.chosenUID, !isConnected(uid) {
          Text("\(input.chosenName ?? "Saved microphone") (not connected)").tag(Optional(uid))
        }
      }
      .labelsHidden()
    }
    .disabled(input.access != .granted || input.devices.devices.isEmpty)
    if input.access == .granted, input.active?.transport == .bluetooth {
      Banner(
        tone: .attention, title: "Bluetooth mics record in lower quality",
        message: "While it records, it switches to a narrower headset profile, and music sounds worse too."
      ) {
        if let wired = wiredMicrophone {
          Button("Use \(wired.name)") { input.choose(wired) }
            .appButton(.secondary, size: .small)
        }
      }
    }
  }

  private var selection: Binding<String?> {
    Binding(
      get: { input.chosenUID },
      set: { uid in
        guard uid != input.chosenUID else { return }
        input.choose(uid.flatMap { uid in input.devices.devices.first { $0.uid == uid } })
      })
  }

  private var systemDefaultTitle: String {
    guard let name = input.devices.systemDefault?.name else { return "System default" }
    return "System default (\(name))"
  }

  private var wiredMicrophone: Microphone? {
    let devices = input.devices.devices
    return devices.first { $0.transport == .builtIn } ?? devices.first { $0.transport == .usb }
  }

  private func isConnected(_ uid: String) -> Bool {
    input.devices.devices.contains { $0.uid == uid }
  }

  private var helper: String {
    if input.access != .granted { return "Allow the microphone above to choose one." }
    if input.devices.devices.isEmpty { return "No microphone is connected." }
    if let uid = input.chosenUID, !isConnected(uid) {
      return "Not connected. Using the system default until it's back."
    }
    return "Used for every dictation."
  }
}

/// The player reads these defaults on every cue, so a change applies to the next one.
private struct SoundFeedbackRows: View {
  let play: () -> Void
  @AppStorage(SoundCueSettings.enabledKey) private var enabled = true
  @AppStorage(SoundCueSettings.volumeKey) private var volume = SoundCueSettings.defaultVolume

  var body: some View {
    SettingRow("Recording sounds", subtitle: "Plays a sound when recording starts or is canceled.") {
      Toggle("Recording sounds", isOn: $enabled).labelsHidden().switchStyle()
    }
    LabeledContent("Volume") {
      HStack(spacing: Space.s.points) {
        Slider(value: $volume, in: 0...1, step: 0.05) { editing in
          if !editing { play() }
        }
        .accessibilityLabel("Recording sound volume")
        Text(volume, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: Space.xxxl.points, alignment: .trailing)
      }
    }
    .disabled(!enabled)
  }
}

private struct HistoryRows: View {
  let history: History
  @AppStorage(TranscriptRetention.defaultsKey) private var retention = TranscriptRetention.never
  @State private var pendingCount: Int?
  @State private var hasTranscripts = false

  var body: some View {
    SettingRow("Delete transcripts", subtitle: "Checked when the app opens and once a day.") {
      Picker("Delete transcripts", selection: $retention) {
        ForEach(TranscriptRetention.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .labelsHidden()
    }
    .onChange(of: retention) { history.applyRetention() }
    SettingRow("Delete all transcripts", subtitle: "Removes your whole history. This can't be undone.") {
      Button("Delete All…", role: .destructive) {
        Task { pendingCount = try? await readyDatabase?.transcriptCount() }
      }
      .appButton(.destructive, size: .small)
      .disabled(!hasTranscripts)
    }
    .task(id: readyDatabase.map(ObjectIdentifier.init)) { await watchHistory() }
    .confirmationDialog(
      dialogTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: pendingCount
    ) { _ in
      Button("Delete All", role: .destructive) { Task { await history.deleteAll() } }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("This can't be undone.")
    }
  }

  private var readyDatabase: AppDatabase? { history.database }

  /// With nothing saved there is nothing to delete, so the button is off instead of offering to
  /// delete 0 transcripts.
  private func watchHistory() async {
    guard let readyDatabase else {
      hasTranscripts = false
      return
    }
    do {
      for try await saved in readyDatabase.hasTranscripts() { hasTranscripts = saved }
    } catch {
      hasTranscripts = false
    }
  }

  private var dialogTitle: String {
    pendingCount == 1 ? "Delete 1 transcript?" : "Delete \(pendingCount ?? 0) transcripts?"
  }

  private var isConfirming: Binding<Bool> {
    Binding(get: { pendingCount != nil }, set: { if !$0 { pendingCount = nil } })
  }
}

extension TranscriptRetention {
  var title: String {
    switch self {
    case .never: "Never"
    case .days7: "After 7 days"
    case .days30: "After 30 days"
    case .days90: "After 90 days"
    }
  }
}

private struct AppearanceRows: View {
  @AppStorage(AppTheme.defaultsKey) private var theme = AppTheme.system
  @AppStorage(WindowBackground.defaultsKey) private var background = WindowBackground.solid
  @AppStorage(AppMenuItem.menuBarShownKey) private var menuBarShown = true
  @AppStorage(OverlayStyle.defaultsKey) private var overlayStyle = OverlayStyle.fallback
  @AppStorage(IslandEdge.defaultsKey) private var islandEdge = IslandEdge.fallback

  var body: some View {
    Picker("Theme", selection: $theme) {
      ForEach(AppTheme.allCases) { theme in
        Text(theme.title).tag(theme)
      }
    }
    .pickerStyle(.segmented)
    .onChange(of: theme) { _, theme in theme.apply() }
    SettingRow(
      "Overlay",
      subtitle: overlayStyle == .notch ? "Displays without a notch show the island at the top." : nil
    ) {
      Picker("Overlay", selection: $overlayStyle) {
        Text("Notch").tag(OverlayStyle.notch)
        Text("Island").tag(OverlayStyle.island)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    if overlayStyle == .island {
      Picker("Island position", selection: $islandEdge) {
        Text("Top").tag(IslandEdge.top)
        Text("Bottom").tag(IslandEdge.bottom)
      }
      .pickerStyle(.segmented)
    }
    // The translucent window relies on the macOS 26 toolbar's scroll edge effect.
    if #available(macOS 26, *) {
      SettingRow("Translucent window", subtitle: "Shows the desktop through the window, blurred.") {
        Toggle("Translucent window", isOn: translucent).labelsHidden().switchStyle()
      }
    }
    SettingRow("Show in menu bar", subtitle: "The Dock menu offers the same actions when it is hidden.") {
      Toggle("Show in menu bar", isOn: $menuBarShown).labelsHidden().switchStyle()
    }
  }

  private var translucent: Binding<Bool> {
    Binding(
      get: { background == .translucent },
      set: { background = $0 ? .translucent : .solid })
  }
}

private struct UpdatesRows: View {
  @Bindable var updates: Updates

  var body: some View {
    SettingRow("Check for updates automatically") {
      Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
        .labelsHidden().switchStyle()
    }
    SettingRow(
      "Install updates automatically",
      subtitle: "Downloads in the background and installs when you quit or restart."
    ) {
      Toggle("Install updates automatically", isOn: $updates.automaticallyInstalls)
        .labelsHidden().switchStyle()
    }
    .disabled(!updates.automaticallyChecks)
  }
}

/// The version and build, selectable so a bug report can quote them exactly.
private struct VersionRow: View {
  private var text: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  var body: some View {
    LabeledContent("Version") {
      Text(text).monospacedDigit().textSelection(.enabled)
    }
  }
}

/// Reads the logs once per export, so Save and Share hand over the same file.
private struct DiagnosticsRow: View {
  let model: AppModel
  @State private var file: DiagnosticsFile?
  /// Set to start an export. `.task(id:)` runs it and cancels it when the row goes away.
  @State private var request: UUID?
  @State private var saving = false
  @State private var saveFailure: String?

  var body: some View {
    SettingRow("Diagnostics", subtitle: saveFailure ?? file?.summary ?? Self.explanation) {
      if let file {
        HStack(spacing: Space.xs.points) {
          Button("Export Again") { export() }.appButton(size: .small)
          ShareLink(item: file, preview: SharePreview(file.filename)) { Text("Share…") }
            .appButton(size: .small)
          Button("Save…") { saving = true }.appButton(size: .small)
        }
      } else if request != nil {
        ProgressView().controlSize(.small)
      } else {
        Button("Export…") { export() }.appButton(size: .small)
      }
    }
    .fileExporter(
      isPresented: $saving, item: file, contentTypes: [.plainText], defaultFilename: file?.filename
    ) { result in
      if case .failure(let error) = result { saveFailure = "Could not save: \(error.localizedDescription)" }
    }
    .task(id: request) {
      guard request != nil else { return }
      let built = await DiagnosticsFile.build(model.diagnosticsSnapshot())
      guard !Task.isCancelled else { return }
      file = built
      request = nil
    }
  }

  private static let explanation =
    "A text file for a bug report, with settings and recent app logs. Transcripts, audio and device names stay out."

  private func export() {
    file = nil
    saveFailure = nil
    request = UUID()
  }
}
