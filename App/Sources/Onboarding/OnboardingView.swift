import AppKit
import DesignSystem
import Hotkeys
import SwiftUI
import Transcription

/// Gets the user to a first dictation in under a minute. One step at a time with a single primary button and
/// a quiet Back and no Skip. Closing the window counts as finishing. Continue waits on the
/// permissions step until both are granted, since nothing after it works without them.
struct OnboardingView: View {
  let model: AppModel
  @State private var step = OnboardingStep.first
  @State private var steps = OnboardingStep.allCases
  @State private var direction = Motion.StepDirection.forward
  /// A direction change applies its step on the next turn; clicks meanwhile would read a stale step.
  @State private var turning = false
  @State private var accessibilityRequested = false
  @State private var celebrating = false
  @State private var barShown = false
  @State private var connectivity = Connectivity()
  @State private var waitingForConnection = false
  @State private var modelJustFinished = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  static let size = CGSize(width: 560, height: 540)

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        page
          .id(step)
          .transition(Motion.stepTransition(direction, reduceMotion: reduceMotion))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      bar
        .opacity(barShown ? 1 : 0)
        .animation(
          Motion.onboardingIntro.resolved(reduceMotion: reduceMotion)?.delay(Motion.introStagger * 4),
          value: barShown)
    }
    .padding(.horizontal, Space.xxxl)
    .padding(.top, Space.xxxl)
    .padding(.bottom, Space.xxl)
    .frame(width: Self.size.width, height: Self.size.height)
    .overlay { ConfettiBurst(trigger: celebrating) }
    .onAppear {
      steps = OnboardingStep.steps(hasNotch: OverlayChoice.hasNotch, including: step)
      model.windowOpener = openWindow
      barShown = true
      connectivity.start()
    }
    .onDisappear {
      connectivity.stop()
      // The close button or ⌘W. The finish button already finished, so this runs once.
      guard model.onboarding, !model.quitting else { return }
      model.finishOnboarding()
      openWindow(id: "main")
    }
    .onChange(of: model.shortcuts.accessibilityGranted) { _, granted in
      guard granted, step == .permissions, accessibilityRequested else { return }
      NSApplication.shared.activate()
    }
    .onChange(of: connectivity.online) { _, online in
      guard online == true,
        waitingForConnection
          || model.models.state(of: ModelDownloadStatus.model).failure == .download(.offline)
      else { return }
      waitingForConnection = false
      model.models.install(ModelDownloadStatus.model)
    }
    .onChange(of: model.models.isInstalling) { _, installing in
      guard !installing, model.models.installedModels.contains(ModelDownloadStatus.model) else { return }
      modelJustFinished = true
      Task {
        try? await Task.sleep(for: Self.readyHold)
        modelJustFinished = false
      }
    }
  }

  static let readyHold: Duration = .seconds(2)

  private var downloadStatus: ModelDownloadStatus {
    ModelDownloadStatus(
      library: model.models, waiting: waitingForConnection, justFinished: modelJustFinished,
      online: connectivity.online)
  }

  private func retryDownload() {
    model.models.install(ModelDownloadStatus.model)
  }

  @ViewBuilder private var page: some View {
    switch step {
    case .welcome:
      WelcomeIntro()
    default:
      VStack(spacing: Space.xl.points) {
        StepHeader(symbol: header.symbol, title: header.title, message: header.message)
        stepContent
      }
    }
  }

  @ViewBuilder private var stepContent: some View {
    switch step {
    case .welcome:
      EmptyView()
    case .permissions:
      PermissionsCard(model: model, accessibilityRequested: $accessibilityRequested)
    case .overlay:
      OverlayChoice(preview: model.previewOverlay)
    case .shortcut:
      ShortcutStep(shortcuts: model.shortcuts)
    case .model:
      ModelSetupCard(library: model.models, status: downloadStatus)
    case .tryIt:
      TryItStep(model: model, done: $celebrating, download: downloadStatus, retry: retryDownload)
    }
  }

  private var header: (symbol: String, title: String, message: String) {
    let content = step.content
    if step == .tryIt, celebrating {
      return ("checkmark", "You're all set", "It works the same in any app.")
    }
    if step == .tryIt { return (content.symbol, content.title, model.shortcuts.bindings.speakInstruction) }
    return (content.symbol, content.title, content.message)
  }

  private var bar: some View {
    HStack(spacing: Space.m.points) {
      StepDots(steps: steps, current: step)
      Spacer(minLength: 0)
      if canGoBack {
        Button("Back", action: back)
          .appButton(.quiet)
          .keyboardShortcut("[", modifiers: .command)
      }
      if let quiet {
        Button(quiet.title, action: quiet.action).appButton(.quiet)
      }
      if let primary {
        Button(primary.title, action: primary.action)
          .appButton(.primary, size: .large)
          .keyboardShortcut(.defaultAction)
          .disabled(waitingForPermissions || waitingForModel)
      }
    }
  }

  private var waitingForPermissions: Bool {
    step == .permissions && !(model.shortcuts.accessibilityGranted && model.input.access == .granted)
  }

  /// Try it needs a model, so the model step waits for one. Offline or failed, Try later
  /// still finishes setup.
  private var waitingForModel: Bool {
    step == .model && model.models.installedModels.isEmpty
  }

  private var primary: (title: String, action: () -> Void)? {
    switch step {
    case .tryIt where !celebrating:
      nil
    case .tryIt:
      (step.content.button, finish)
    default:
      (step.content.button, continueTapped)
    }
  }

  private var quiet: (title: String, action: () -> Void)? {
    switch step {
    case .tryIt where !celebrating:
      ("Try later", finish)
    case .model where waitingForModel && [.offline, .failed].contains(downloadStatus):
      ("Try later", finish)
    default:
      nil
    }
  }

  private func continueTapped() {
    switch step {
    case .welcome:
      startModelDownloadIfNeeded()
      advance()
    default:
      advance()
    }
  }

  private var canGoBack: Bool {
    step.previous(in: steps) != nil && !(step == .tryIt && celebrating)
  }

  private func advance() {
    guard let next = step.next(in: steps) else { return }
    go(to: next, .forward)
  }

  private func back() {
    guard canGoBack, let previous = step.previous(in: steps) else { return }
    go(to: previous, .backward)
  }

  /// The leaving page keeps the transition it last rendered with, so a change of direction
  /// renders once with the new direction before the step changes.
  private func go(to target: OnboardingStep, _ newDirection: Motion.StepDirection) {
    guard !turning else { return }
    let animation = Motion.onboardingStep.resolved(reduceMotion: reduceMotion)
    guard newDirection != direction else {
      withAnimation(animation) { step = target }
      return
    }
    direction = newDirection
    turning = true
    Task { @MainActor in
      withAnimation(animation) { step = target }
      turning = false
    }
  }

  private func finish() {
    model.finishOnboarding()
    openWindow(id: "main")
    dismissWindow(id: Onboarding.windowID)
  }

  /// The model downloads while the user reads the next steps, so it is usually ready by Try it.
  /// Offline, it waits for a connection instead of starting a download that would fail.
  private func startModelDownloadIfNeeded() {
    let library = model.models
    guard library.installedModels.isEmpty, !library.isInstalling else { return }
    if connectivity.online == false {
      waitingForConnection = true
    } else {
      library.install(ModelDownloadStatus.model)
    }
  }
}
