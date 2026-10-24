#if DEBUG
  import AppKit
  import AudioCapture
  import Dictation
  import DictationCore
  import Models
  import Paste
  import Transcription
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "dictation-harness")

  /// `scripts/latency/dictation-harness.sh`. Launch with `-dictationHarness SCENARIO.json
  /// -harnessOutput PATH -dataFolder DIR` to run the real dictation pipeline, overlay and speech
  /// model on WAV fixtures instead of the microphone. A scenario that names a model loads that one
  /// without changing the active model, and skips the runs when it isn't installed. Each run
  /// presses the shortcut, holds it for the fixture's length and releases it; the paste is
  /// recorded instead of posted. One JSON line per run and a summary line go to PATH, then the app
  /// quits. The hotkeys never start, so no Accessibility grant is needed, and no key event is
  /// posted.
  /// Resumes a continuation with the first answer only.
  @MainActor private final class FirstAnswer {
    private var continuation: CheckedContinuation<Provisioner.Preparation?, Never>?

    init(_ continuation: CheckedContinuation<Provisioner.Preparation?, Never>) {
      self.continuation = continuation
    }

    func give(_ answer: Provisioner.Preparation?) {
      continuation?.resume(returning: answer)
      continuation = nil
    }
  }

  @MainActor enum DictationHarness {
    static var isRequested: Bool {
      UserDefaults.standard.string(forKey: "dictationHarness") != nil
    }

    private static let modelWait = Duration.seconds(180)
    /// How long a run may take past the fixture's own length.
    private static let runWait = Duration.seconds(30)
    /// Lets the overlay hide and the model idle between runs, as between two real dictations.
    private static let gap = Duration.milliseconds(1500)

    private static var results: [DictationRunResult] = []
    private static var output: [String] = []
    private static var feedbackMs: Double?
    private static var shownSession: SessionID?
    private static var terminal: CheckedContinuation<DictationPhase?, Never>?
    private static var terminalID = 0

    struct Parts {
      let provisioner: Provisioner
      let preferences: ModelPreferences
      let runtime: TranscriptionRuntime
      let history: History
      let feedback: DictationFeedback
      let capture: AudioCapture
    }

    private enum Outcome {
      case played
      case skipped(String)
      case failed(String)
    }

    static func run(_ parts: Parts) async {
      let (model, outcome) = await drive(parts)
      var skipped: String?
      var failure: String?
      switch outcome {
      case .played: break
      case .skipped(let reason): skipped = reason
      case .failed(let reason):
        failure = reason
        logger.error("Dictation harness failed: \(reason, privacy: .public)")
      }
      append(
        DictationHarnessSummary(
          model: model?.rawValue, runs: results.count, withText: results.filter { !$0.text.isEmpty }.count,
          matched: results.filter(\.match).count, skipped: skipped, failure: failure))
      logger.notice("Dictation harness finished")
      // From a main-actor job, terminate's nested event loop never runs the main-actor shutdown
      // task that answers terminateLater, so the app would never quit. A run loop timer is not one.
      NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func drive(_ parts: Parts) async -> (ModelID?, Outcome) {
      guard let path = UserDefaults.standard.string(forKey: "dictationHarness") else {
        return (nil, .failed("no scenario"))
      }
      let scenario: DictationScenario
      var fixtures: [String: [Float]] = [:]
      do {
        scenario = try DictationScenario.load(URL(filePath: path))
        for run in scenario.runs where fixtures[run.fixture] == nil {
          fixtures[run.fixture] = try FixtureCapture.samples(of: URL(filePath: run.fixture))
        }
      } catch {
        return (nil, .failed("scenario or fixture unreadable: \(error)"))
      }
      var model = scenario.model ?? parts.preferences.active ?? .preferred
      var prepared = await prepare(model, parts)
      if scenario.model == nil, prepared == .notInstalled, let installed = await installedHosted(parts) {
        (model, prepared) = installed
      }
      switch prepared {
      case nil:
        return (model, .failed("\(model.rawValue) did not install within \(modelWait)"))
      case .ready(let resolved):
        if let failure = await load(resolved, in: parts.runtime) { return (model, .failed(failure)) }
      case .notInstalled where scenario.model != nil:
        return (model, .skipped("\(model.rawValue) is not installed"))
      case .notInstalled:
        return (model, .failed("\(model.rawValue) is not installed; download it in the app first"))
      case .unavailable:
        return (model, .skipped("\(model.rawValue) can't run on this Mac"))
      case .needsLanguage:
        return (model, .failed("\(model.rawValue) has no language; choose one in the app first"))
      case .failed(let error):
        return (model, .failed("\(model.rawValue) did not install: \(error)"))
      }
      await parts.history.open()
      parts.feedback.prepare()

      let fixture = FixtureCapture()
      let recorder = PasteRecorder()
      let (commands, keys) = AsyncStream<StampedCommand>.makeStream()
      let pipeline = DictationPipeline(
        services: services(parts, commands: commands, fixture: fixture, recorder: recorder))
      let pipelineRun = Task.detached { await pipeline.run() }
      let feedback = parts.feedback
      let updates = Task {
        for await update in pipeline.updates {
          feedback.show(update)
          observe(update)
        }
      }
      defer {
        keys.finish()
        pipelineRun.cancel()
        updates.cancel()
      }

      for (index, run) in scenario.runs.enumerated() {
        let samples = fixtures[run.fixture] ?? []
        fixture.load(samples)
        feedbackMs = nil
        _ = recorder.take()
        let (down, up): (DictationCommand, DictationCommand) =
          run.mode == .pushToTalk ? (.pushToTalkStart, .pushToTalkStop) : (.toggle, .toggle)
        var presser: Task<HostTime, Never>?
        let length = Duration.seconds(Double(samples.count) / FixtureCapture.sampleRate)
        let phase = await untilTerminal(within: length + runWait) {
          presser = Task {
            keys.yield(StampedCommand(command: down, at: .now()))
            try? await Task.sleep(for: length)
            let releasedAt = HostTime.now()
            keys.yield(StampedCommand(command: up, at: releasedAt))
            return releasedAt
          }
        }
        let releasedAt = await presser?.value
        let paste = recorder.take()
        let text = paste?.text ?? ""
        let rate = run.expected.map { WordErrorRate.rate(reference: $0, hypothesis: text) }
        let result = DictationRunResult(
          run: index + 1, fixture: URL(filePath: run.fixture).lastPathComponent, mode: run.mode.rawValue,
          text: text, expected: run.expected, wordErrorRate: rate,
          match: !text.isEmpty && (rate.map { $0 <= scenario.maxWordErrorRate } ?? true),
          lb01Ms: feedbackMs,
          lb02Ms: paste.flatMap { paste in releasedAt.map { paste.at.milliseconds(since: $0) } },
          failure: phase.flatMap(failure(of:)) ?? (phase == nil ? "timed out" : nil))
        results.append(result)
        append(result)
        try? await Task.sleep(for: gap)
      }
      return (model, .played)
    }

    private static func failure(of phase: DictationPhase) -> String? {
      if case .failed(let reason) = phase { return String(describing: reason) }
      return nil
    }

    private static func observe(_ update: DictationUpdate) {
      if let pressedAt = update.pressedAt, update.session != shownSession, update.phase.showsRecording {
        shownSession = update.session
        feedbackMs = HostTime.now().milliseconds(since: pressedAt)
      }
      switch update.phase {
      case .complete, .failed:
        let waiter = terminal
        terminal = nil
        waiter?.resume(returning: update.phase)
      default: break
      }
    }

    /// Runs `trigger` and waits for the session to complete or fail, or nil after `wait`.
    private static func untilTerminal(within wait: Duration, _ trigger: () -> Void) async -> DictationPhase? {
      terminalID += 1
      let id = terminalID
      return await withCheckedContinuation { continuation in
        terminal = continuation
        trigger()
        Task {
          try? await Task.sleep(for: wait)
          guard terminalID == id, let waiter = terminal else { return }
          terminal = nil
          waiter.resume(returning: nil)
        }
      }
    }

    /// Nil when installing a system model takes longer than `modelWait`. The install is cancelled
    /// but not awaited, so an install that ignores the cancel can't hold the run.
    private static func prepare(_ model: ModelID, _ parts: Parts) async -> Provisioner.Preparation? {
      let provisioner = parts.provisioner
      let preferences = parts.preferences
      let work = Task { await provisioner.prepare(model, preferences: preferences) }
      return await withCheckedContinuation { continuation in
        let answer = FirstAnswer(continuation)
        let deadline = Task {
          try? await Task.sleep(for: modelWait)
          work.cancel()
          answer.give(nil)
        }
        Task {
          answer.give(await work.value)
          deadline.cancel()
        }
      }
    }

    /// With no model named and the stored one missing, the first installed hosted model, as the
    /// app itself falls back at launch. Hosted models only, since preparing one installs nothing.
    private static func installedHosted(_ parts: Parts) async -> (ModelID, Provisioner.Preparation)? {
      for model in [ModelID.preferred] + ModelID.allCases {
        guard case .hosted = model.provider else { continue }
        let prepared = await parts.provisioner.prepare(model, preferences: parts.preferences)
        if case .ready = prepared { return (model, prepared) }
      }
      return nil
    }

    private static func load(_ model: ResolvedModel, in runtime: TranscriptionRuntime) async -> String? {
      await runtime.activate(model)
      let state = await withTaskGroup(of: RuntimeState?.self) { group in
        group.addTask { await runtime.settled() }
        group.addTask {
          try? await Task.sleep(for: modelWait)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
      let name = model.id.rawValue
      switch state {
      case .ready: return nil
      case .failed: return "\(name) failed to load"
      case .notInstalled, .loading: return "\(name) did not load"
      case nil: return "\(name) did not load within \(modelWait)"
      }
    }

    private static func append(_ line: some Encodable) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard let data = try? encoder.encode(line) else { return }
      output.append(String(decoding: data, as: UTF8.self))
      guard let path = UserDefaults.standard.string(forKey: "harnessOutput") else { return }
      do {
        try (output.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
      } catch {
        logger.error("Writing the results failed: \(String(describing: error), privacy: .public)")
      }
    }

    private static func services(
      _ parts: Parts, commands: AsyncStream<StampedCommand>, fixture: FixtureCapture, recorder: PasteRecorder
    ) -> DictationServices {
      let runtime = parts.runtime
      let history = parts.history
      var services = DictationServices.live(
        commands: commands, phaseDidChange: { _ in }, capture: parts.capture, runtime: runtime,
        paster: Paster(), playCue: { _ in }, save: { await history.save($0) })
      services.startCapture = { _, _ in
        fixture.start()
        await runtime.warm(listening: { fixture.soFar() })
      }
      services.stopCapture = { _ in fixture.stop() }
      services.cancelCapture = {
        await runtime.coolDown()
        fixture.cancel()
      }
      services.paste = { transcript, _ in recorder.paste(transcript) }
      services.completeManualPaste = { .ended }
      services.abandonManualPaste = {}
      return services
    }
  }
#endif
