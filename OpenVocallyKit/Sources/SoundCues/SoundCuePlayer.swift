import AVFoundation
import DictationCore
import Synchronization
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "sound")

/// Plays the start, cancel and error cues. `play` never blocks: the audio work
/// runs on the output actor's own queue.
public final class SoundCuePlayer: Sendable {
  private let output: CueOutput
  private let gate = Mutex(CueGate())
  private let settings: @Sendable () -> SoundCueSettings
  private let requests: AsyncStream<CueRequest>.Continuation

  /// A cue with no file, or one that fails to decode, is silent.
  public init(
    sounds: [SoundCue: URL],
    settings: @escaping @Sendable () -> SoundCueSettings = { SoundCueSettings.load(from: .standard) }
  ) {
    let output = CueOutput(sounds: sounds)
    self.output = output
    self.settings = settings
    let (stream, requests) = AsyncStream<CueRequest>.makeStream()
    self.requests = requests
    // One drain task, so cues play in the order they were asked for.
    Task {
      for await request in stream { await output.play(request) }
    }
  }

  deinit {
    requests.finish()
  }

  /// Decodes every cue. Call before the first press.
  public func prime() async {
    await output.prime()
  }

  public func play(_ cue: SoundCue) {
    let settings = settings()
    guard let gain = gate.withLock({ $0.admit(cue, at: .now, settings: settings) }) else { return }
    requests.yield(CueRequest(cue: cue, gain: gain, enqueuedAt: .now))
  }
}

private struct CueRequest: Sendable {
  let cue: SoundCue
  let gain: Float
  let enqueuedAt: ContinuousClock.Instant
}

/// Owns the output engine. Runs on its own serial queue because AVAudioEngine calls block.
private actor CueOutput {
  private static let warmDuration: Duration = .seconds(25)
  private static let startAttempts = 5

  private let queue = DispatchSerialQueue(label: "com.openvocally.sound", qos: .userInitiated)
  private let sounds: [SoundCue: URL]
  private var engine = AVAudioEngine()
  private var players: [SoundCue: (node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer)] = [:]
  private var primed = false
  private var idleTimer: Task<Void, Never>?
  private var configurationObserver: (any NSObjectProtocol)?
  private var lastScheduled: (cue: SoundCue, gain: Float, at: ContinuousClock.Instant)?

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(sounds: [SoundCue: URL]) {
    self.sounds = sounds
  }

  func prime() {
    guard !primed else { return }
    primed = true
    var buffers: [SoundCue: AVAudioPCMBuffer] = [:]
    for cue in SoundCue.allCases {
      guard let url = sounds[cue] else {
        logger.notice("No sound for cue \(String(describing: cue), privacy: .public)")
        continue
      }
      do {
        let file = try AVAudioFile(forReading: url)
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        buffers[cue] = buffer
      } catch {
        logger.error(
          "Cue \(String(describing: cue), privacy: .public) failed to decode: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    buildEngine(playing: buffers)
  }

  /// An engine that outlives an output change keeps each node's frame limit from the old
  /// device. Moving from 48 kHz speakers to 44.1 kHz headphones then fails every render, so
  /// each change gets a fresh engine.
  private func buildEngine(playing buffers: [SoundCue: AVAudioPCMBuffer]) {
    if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    engine.stop()
    engine = AVAudioEngine()
    players = buffers.mapValues { buffer in
      let node = AVAudioPlayerNode()
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
      return (node, buffer)
    }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      Task { await self?.configurationChanged() }
    }
    engine.prepare()
  }

  /// The engine stops itself on an output change; the next cue starts a rebuilt one. A start
  /// cue the change cut off plays once more on the new route.
  private func configurationChanged() async {
    logger.notice("Sound output configuration changed")
    buildEngine(playing: players.mapValues(\.buffer))
    guard let last = lastScheduled,
      CueGate.shouldReplay(last.cue, scheduledAt: last.at, changedAt: .now),
      let player = players[last.cue]
    else { return }
    lastScheduled = nil
    logger.notice("Replaying the start cue after an output change")
    guard await startEngine() else { return }
    restart(player.node, with: player.buffer, gain: last.gain)
  }

  fileprivate func play(_ request: CueRequest) async {
    prime()
    guard let player = players[request.cue] else { return }
    guard await startEngine() else { return }
    guard !CueGate.isStale(request.cue, enqueuedAt: request.enqueuedAt, now: .now) else {
      logger.notice("Start cue waited too long; skipping it")
      return
    }
    restart(player.node, with: player.buffer, gain: request.gain)
    lastScheduled = (request.cue, request.gain, .now)
    idleTimer?.cancel()
    idleTimer = Task {
      try? await Task.sleep(for: Self.warmDuration)
      guard !Task.isCancelled else { return }
      stopIfIdle()
    }
  }

  /// Synchronous so the schedule call does not wait for playback to end.
  private func restart(_ node: AVAudioPlayerNode, with buffer: AVAudioPCMBuffer, gain: Float) {
    node.stop()
    node.volume = gain
    node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    // play() on a stopped engine raises an exception Swift cannot catch.
    if !engine.isRunning { try? engine.start() }
    guard engine.isRunning else {
      node.stop()
      logger.error("Sound output stopped before the cue; skipping it")
      return
    }
    node.play()
  }

  private func stopIfIdle() {
    guard !Task.isCancelled else { return }
    engine.stop()
    engine.prepare()
  }

  private func startEngine() async -> Bool {
    for attempt in 1...Self.startAttempts {
      if engine.isRunning { return true }
      do {
        try engine.start()
        return true
      } catch {
        logger.notice(
          "Sound output start attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        if attempt < Self.startAttempts { try? await Task.sleep(for: .milliseconds(120)) }
      }
    }
    logger.error("Sound output did not start; skipping the cue")
    return false
  }
}
