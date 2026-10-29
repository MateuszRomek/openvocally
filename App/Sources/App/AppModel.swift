import AppKit
import Dictation
import DictationCore
import Hotkeys
import Models
import Observation
import Overlay
import Paste
import SoundCues
import Storage
import SwiftUI
import Transcription
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "app")

/// The composition root. It owns the five areas, runs the launch and shutdown order, the menu
/// actions, navigation and onboarding, and the system watchers that span areas.
@MainActor @Observable final class AppModel {
  let models: ModelLibrary
  let input = AudioInput()
  let shortcuts: Shortcuts
  let history: History
  let feedback = DictationFeedback()
  let updates = Updates()
  /// The add-ons this build ships.
  let extensions: AppExtensions

  /// The first-run onboarding is on screen. Launch then leaves the permission prompts to its
  /// steps.
  private(set) var onboarding = Onboarding.neededAtLaunch
  /// The onboarding window's view identity. The Window scene keeps its views' @State after a
  /// close, so each replay takes a new identity and starts at the first step.
  private(set) var onboardingRun = 0
  /// Set at the start of quitting, so windows closing with the app don't count as the user
  /// closing onboarding.
  @ObservationIgnored private(set) var quitting = false
  /// Opens the main window from paths outside SwiftUI, such as the Dock menu.
  @ObservationIgnored var windowOpener: OpenWindowAction?

  /// The main window's sidebar selection. Command-comma sets it to Settings.
  var screen: Screen = .home

  /// The sidebar badge and the Home banner.
  var needsSetup: Bool {
    !shortcuts.accessibilityGranted || input.access == .denied || models.needsModel
  }

  @ObservationIgnored private var paster: Paster?
  @ObservationIgnored private let cues = SoundCuePlayer(sounds: AppModel.cueSounds())
  @ObservationIgnored private var launchTask: Task<Void, Never>?
  @ObservationIgnored private var pipeline: DictationPipeline?
  @ObservationIgnored private var pipelineRun: Task<Void, Never>?
  @ObservationIgnored private var systemWatch: Task<Void, Never>?
  @ObservationIgnored private var shutdown: Task<Void, Never>?

  @ObservationIgnored private let transcription: TranscriptionRuntime
  @ObservationIgnored private let provisioner: Provisioner
  @ObservationIgnored private let preferences: ModelPreferences

  init(extensions: AppExtensions) {
    self.extensions = extensions
    var folder = ModelFolder.default(bundleIdentifier: AppData.bundleIdentifier)
    #if DEBUG
      // -modelFolder <absolute path> (make onboarding FRESH=1): an empty folder to test the
      // download without deleting the real models.
      if let path = UserDefaults.standard.string(forKey: "modelFolder"), path.hasPrefix("/") {
        folder = ModelFolder(root: URL(filePath: path, directoryHint: .isDirectory))
      }
    #endif
    let transcription = TranscriptionRuntime.live(folder: folder)
    self.transcription = transcription
    let provisioner = Provisioner(folder: folder, fetcher: URLSessionFetcher(), system: AppleSpeech.store())
    self.provisioner = provisioner
    let preferences = ModelPreferences(defaults: .standard)
    self.preferences = preferences
    models = ModelLibrary(provisioner: provisioner, runtime: transcription, preferences: preferences)
    let history = History()
    self.history = history
    shortcuts = Shortcuts(history: history, promptsForAccessibility: !Onboarding.neededAtLaunch)
  }

  private static func cueSounds() -> [SoundCue: URL] {
    var sounds: [SoundCue: URL] = [:]
    for cue in SoundCue.allCases {
      sounds[cue] = Bundle.main.url(forResource: "cue-\(cue)", withExtension: "wav")
    }
    return sounds
  }

  func start() {
    guard launchTask == nil else { return }
    // A user who already had both permissions skipped onboarding; losing one later must not
    // show the first-run flow again.
    if !onboarding { UserDefaults.standard.set(true, forKey: Onboarding.completedKey) }
    launchTask = Task { await launch() }
  }

  /// The model load, the mic prompt and the Accessibility wait overlap; only the hotkeys
  /// wait, and only for Accessibility.
  private func launch() async {
    #if DEBUG
      if TranscriptsHarness.isRequested {
        await TranscriptsHarness.run(self, database: await history.open())
        return
      }
      if DictationHarness.isRequested {
        await DictationHarness.run(
          .init(
            provisioner: provisioner, preferences: preferences, runtime: transcription, history: history,
            feedback: feedback, capture: input.capture))
        return
      }
    #endif
    let models = models
    Task { await models.start() }

    input.start(preparing: !onboarding || input.access == .granted)

    let cues = cues
    Task { await cues.prime() }

    let paster = Paster()
    self.paster = paster
    let capture = input.capture
    RetiredOverlayDefaults.remove(from: .standard)
    feedback.prepare()
    Task {
      for await levels in capture.levels {
        feedback.meter(levels.bands)
        shortcuts.trialHeard(level: levels.level)
      }
    }
    #if DEBUG
      if OverlayDemo.isRequested {
        await feedback.runDemo()
        return
      }
      if OverlayProbe.isRequested {
        await feedback.runProbe()
        return
      }
      if DiagnosticsHarness.isRequested {
        await DiagnosticsHarness.run(self)
        return
      }
    #endif
    let archive = RecordingArchive(root: AppData.directory.appending(path: "recordings"))
    async let archiveReady: Void = archive.prepare()
    await history.open()
    guard let hotkeys = await shortcuts.start() else { return }
    systemWatch = Task { await watchSystem(hotkeys) }
    Task { await warmFocusProbe() }
    await archiveReady

    let pipeline = DictationPipeline(
      services: .live(
        commands: hotkeys.events, phaseDidChange: { hotkeys.phaseDidChange(to: $0) },
        capture: capture, runtime: transcription, paster: paster,
        playCue: { cues.play($0) },
        save: { [history] in await history.save($0) },
        recordings: archive.sink))
    self.pipeline = pipeline
    pipelineRun = Task.detached { await pipeline.run() }

    for await update in pipeline.updates {
      if shortcuts.absorb(update) { continue }
      feedback.show(update)
    }
  }

  /// The Transcripts and Home Try Again when the database failed to open.
  func reopenDatabase() {
    Task {
      // Checked inside the task, after `open()` of an earlier click has set `.opening`, so a
      // double click opens the database once.
      guard case .failed = history.state else { return }
      guard let database = await history.open() else { return }
      await shortcuts.adoptStore(database)
    }
  }

  func replayOnboarding() {
    // While it is on screen, a new identity would tear it down mid-run and its close path would
    // finish it.
    if !onboarding { onboardingRun += 1 }
    onboarding = true
    shortcuts.promptsForAccessibility = false
    NSApplication.shared.activate()
    windowOpener?(id: Onboarding.windowID)
  }

  /// A permission skipped in onboarding is left to the Home banner, so the hotkey loop doesn't
  /// raise the Accessibility alert right after. The mic is still asked now if it never was, so
  /// the alert can't land on the first shortcut press and clip the first words.
  func finishOnboarding() {
    UserDefaults.standard.set(true, forKey: Onboarding.completedKey)
    onboarding = false
    shortcuts.promptsForAccessibility = false
    input.askIfNeverAsked()
  }

  /// Plays the start cue at the saved volume, after the volume slider is let go.
  func previewSoundCue() {
    cues.play(.start)
  }

  func perform(_ item: AppMenuItem) {
    switch item {
    case .toggleDictation: pipeline?.send(.toggle)
    case .pasteLast: pipeline?.send(.pasteLast)
    case .openWindow: showWindow()
    case .settings:
      screen = .settings
      showWindow()
    case .checkForUpdates:
      switch updates.state {
      case .none: updates.checkForUpdates()
      case .available: updates.showAvailableUpdate()
      case .readyToInstall: updates.installNow()
      }
    case .quit: NSApplication.shared.terminate(nil)
    }
  }

  private func showWindow() {
    NSApplication.shared.activate()
    windowOpener?(id: onboarding ? Onboarding.windowID : "main")
  }

  /// Stops everything in order. A second call waits for the first. The clipboard is restored even when the stop
  /// runs past the deadline.
  func shutDown(within limit: Duration = .seconds(2.5)) async {
    quitting = true
    if shutdown == nil {
      shutdown = Task {
        let finished = await withDeadline(limit) { await self.stopInOrder() } != nil
        if !finished { logger.notice("Shutdown passed its deadline") }
        await paster?.flushPendingRestore()
      }
    }
    await shutdown?.value
  }

  /// Shutdown order: pipeline, recording, transcription, shortcuts, retention, database. Cancelling the
  /// pipeline run aborts an in-flight transcription; a history save still queued is dropped.
  /// An inference that ignores cancellation gets 1.5 s and transcription shutdown 0.8 s, so the
  /// later stages still run.
  private func stopInOrder() async {
    launchTask?.cancel()
    systemWatch?.cancel()
    pipelineRun?.cancel()
    if let pipelineRun { _ = await withDeadline(.seconds(1.5)) { await pipelineRun.value } }
    await input.capture.cancel()
    let transcription = transcription
    _ = await withDeadline(.seconds(0.8)) { await transcription.shutDown() }
    shortcuts.stop()
    await history.close()
  }

  /// macOS can disable the tap while the app sleeps or loses focus, and the tap must go when
  /// Accessibility does. A recording is canceled before sleep so no capture straddles it.
  private func watchSystem(_ hotkeys: Hotkeys) async {
    let workspace = NSWorkspace.shared.notificationCenter
    let shortcuts = shortcuts
    await withDiscardingTaskGroup { group in
      group.addTask {
        for await _ in NotificationCenter.default.notifications(
          named: NSApplication.didBecomeActiveNotification)
        {
          await shortcuts.check(hotkeys, reason: "app activation")
        }
      }
      group.addTask {
        for await _ in workspace.notifications(named: NSWorkspace.willSleepNotification) {
          await self.cancelRecordingBeforeSleep()
        }
      }
      group.addTask {
        for await _ in workspace.notifications(named: NSWorkspace.didWakeNotification) {
          await shortcuts.check(hotkeys, reason: "wake")
        }
      }
      // Posted when any app's Accessibility switch changes. The new grant reads back a moment
      // later, so a check right away could still see the old one.
      group.addTask {
        for await _ in DistributedNotificationCenter.default().notifications(
          named: Notification.Name("com.apple.accessibility.api"))
        {
          try? await Task.sleep(for: .milliseconds(250))
          await shortcuts.check(hotkeys, reason: "accessibility change")
        }
      }
      // A suspended tap waits for the grant once a second, as the start loop does.
      group.addTask {
        var installed = true
        while !Task.isCancelled {
          try? await Task.sleep(for: installed ? .seconds(30) : .seconds(1))
          installed = await shortcuts.check(hotkeys, reason: "health check")
        }
      }
    }
  }

  private func cancelRecordingBeforeSleep() {
    guard feedback.phase.showsRecording else { return }
    pipeline?.send(.cancel)
  }

  /// The first Accessibility read of an app costs 16 to 39 ms and later reads under
  /// 1 ms, so each app is read once as it comes to the front instead of on the paste.
  private func warmFocusProbe() async {
    await Self.warmFocus(of: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    for await notification in NSWorkspace.shared.notificationCenter.notifications(
      named: NSWorkspace.didActivateApplicationNotification)
    {
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      await Self.warmFocus(of: app?.processIdentifier)
    }
  }

  @concurrent private nonisolated static func warmFocus(of processIdentifier: pid_t?) async {
    guard let processIdentifier, processIdentifier != ProcessInfo.processInfo.processIdentifier else {
      return
    }
    switch ProcessInfo.processInfo.thermalState {
    case .nominal, .fair: FocusProbe.warm(processIdentifier: processIdentifier)
    default: return
    }
  }
}
