import AudioCapture
import DictationCore
import Paste
import Synchronization
import Transcription
import os

/// Published after any change of phase, session, hold or trial result.
public struct DictationUpdate: Sendable, Equatable {
  public let phase: DictationPhase
  public let session: SessionID?
  public let pressedAt: HostTime?
  /// nil for a chord, toggle or menu session.
  public let hold: Hold?
  public let trialResult: TrialResult?
}

private let logger = Logger(subsystem: "com.openvocally.app", category: "pipeline")

/// Runs the machine. Hotkey events and every completion enter one FIFO inbox, and the
/// machine is a local of the one loop that drains it, so it has a single writer. The loop
/// never awaits a service: effects become jobs whose completions come back through the inbox.
public final class DictationPipeline: Sendable {
  typealias Job = @Sendable () async -> Void

  public let updates: AsyncStream<DictationUpdate>
  private let updatesContinuation: AsyncStream<DictationUpdate>.Continuation
  private let inbox: AsyncStream<DictationEvent>
  private let inboxContinuation: AsyncStream<DictationEvent>.Continuation
  private let services: DictationServices
  /// The inbox is an `AsyncStream`, which allows one consumer only.
  private let hasRun = Mutex(false)

  public init(services: DictationServices) {
    (updates, updatesContinuation) = AsyncStream.makeStream()
    (inbox, inboxContinuation) = AsyncStream.makeStream()
    self.services = services
  }

  /// Sends a command from outside the hotkeys, such as a menu item, through the same inbox.
  public func send(_ command: DictationCommand) {
    inboxContinuation.yield(.command(command, at: .now()))
  }

  /// Runs until the calling task is cancelled. Call once.
  @concurrent public func run() async {
    let firstRun = hasRun.withLock { hasRun in
      defer { hasRun = true }
      return !hasRun
    }
    precondition(firstRun, "DictationPipeline.run() called twice")
    // Capture and transcription each run one job at a time in order. A cancel queued behind
    // an in-flight start cannot reach the next session's recording, and transcriptions never
    // overlap. Recording audio and history saves share their own queue, so a keep
    // lands before its discard or fail, saves commit in session order, and disk writes never
    // delay the transcription. Manual paste completions and abandons share a queue, so a ⌘V
    // and an Escape reach the Paster in the order they were pressed.
    let (captureJobs, captureQueue) = AsyncStream<Job>.makeStream()
    let (manualPasteJobs, manualPasteQueue) = AsyncStream<Job>.makeStream()
    let (transcriptionJobs, transcriptionQueue) = AsyncStream<Job>.makeStream()
    let (recordingJobs, recordingQueue) = AsyncStream<Job>.makeStream()
    let services = services
    let inbox = inboxContinuation
    await withDiscardingTaskGroup { group in
      group.addTask { for await job in captureJobs { await job() } }
      group.addTask { for await job in transcriptionJobs { await job() } }
      group.addTask { for await job in recordingJobs { await job() } }
      group.addTask { for await job in manualPasteJobs { await job() } }
      group.addTask {
        for await stamped in services.commands {
          inbox.yield(.command(stamped.command, at: stamped.at))
        }
      }
      var machine = DictationMachine()
      for await event in self.inbox {
        let before = (machine.phase, machine.currentSession, machine.hold, machine.trialResult)
        let effects = machine.handle(event)
        if (machine.phase, machine.currentSession, machine.hold, machine.trialResult) != before {
          if (machine.phase, machine.currentSession) != (before.0, before.1) {
            logger.notice("Phase \(String(describing: machine.phase), privacy: .public)")
            services.phaseDidChange(machine.phase)
          }
          updatesContinuation.yield(
            DictationUpdate(
              phase: machine.phase, session: machine.currentSession, pressedAt: machine.pressedAt,
              hold: machine.hold, trialResult: machine.trialResult))
        }
        for effect in effects {
          switch route(effect) {
          case .capture(let job): captureQueue.yield(job)
          case .transcription(let job): transcriptionQueue.yield(job)
          case .recording(let job): recordingQueue.yield(job)
          case .manualPaste(let job): manualPasteQueue.yield(job)
          case .concurrent(let job): group.addTask { await job() }
          case .now(let action): action()
          }
        }
      }
      captureQueue.finish()
      transcriptionQueue.finish()
      recordingQueue.finish()
      manualPasteQueue.finish()
      group.cancelAll()
    }
    updatesContinuation.finish()
  }

  private enum Route {
    case capture(Job)
    case transcription(Job)
    case recording(Job)
    case manualPaste(Job)
    case concurrent(Job)
    case now(@Sendable () -> Void)
  }

  private func route(_ effect: DictationEffect) -> Route {
    let services = services
    let inbox = inboxContinuation
    switch effect {
    case .startCapture(let id, let pressedAt):
      return .capture {
        Latency.captureRequested(pressedAt: pressedAt)
        do throws(CaptureError) {
          try await services.startCapture(pressedAt) { error in Self.report(error, for: id, to: inbox) }
          inbox.yield(.captureStarted(id))
        } catch {
          Self.report(error, for: id, to: inbox)
        }
      }
    case .stopCapture(let id, let releasedAt):
      return .capture {
        do throws(CaptureError) {
          inbox.yield(.captureStopped(id, samples: try await services.stopCapture(releasedAt)))
        } catch {
          Self.report(error, for: id, to: inbox)
        }
      }
    case .cancelCapture:
      return .capture { await services.cancelCapture() }
    case .transcribe(let id, let samples):
      return .transcription {
        do throws(TranscriptionError) {
          let start = HostTime.now()
          let text = try await services.transcribe(samples)
          Latency.stage(.transcribe, since: start)
          inbox.yield(Transcript(text).map { .transcribed(id, $0) } ?? .failed(id, .noSpeech))
        } catch .noSpeech {
          logger.notice("No speech in the recording")
          inbox.yield(.failed(id, .noSpeech))
        } catch .modelNotInstalled {
          inbox.yield(.failed(id, .modelNotInstalled))
        } catch {
          logger.error("Transcription failed: \(String(describing: error), privacy: .public)")
          inbox.yield(.failed(id, .transcriptionError))
        }
      }
    case .process(let id, let transcript):
      return .concurrent {
        let start = HostTime.now()
        let processed = await services.processor.process(transcript)
        Latency.stage(.process, since: start)
        inbox.yield(.processed(id, processed))
      }
    case .paste(let id, let transcript):
      return .concurrent { inbox.yield(Self.event(for: await services.paste(transcript, .dictation), id)) }
    case .pasteLast(let id, let transcript):
      return .concurrent { inbox.yield(Self.event(for: await services.paste(transcript, .pasteLast), id)) }
    case .expireManualPaste(let id, let after):
      return .concurrent {
        await services.sleep(after)
        inbox.yield(.manualPasteExpired(id))
      }
    case .completeManualPaste(let id):
      return .manualPaste {
        switch await services.completeManualPaste() {
        case .pasted(let target): inbox.yield(.pasted(id, target: target, at: .now()))
        case .ended: inbox.yield(.manualPasteExpired(id))
        case .notInTextField: logger.notice("⌘V outside a text field; the manual paste window stays open")
        }
      }
    case .abandonManualPaste:
      return .manualPaste { await services.abandonManualPaste() }
    case .endTerminalDisplay(let id, let after):
      return .concurrent {
        await services.sleep(after)
        inbox.yield(.terminalDisplayEnded(id))
      }
    case .confirmHold(let id, let at):
      return .concurrent {
        await services.sleep(max(.zero, at.duration(since: .now())))
        inbox.yield(.holdConfirmed(id))
      }
    case .latency(let mark):
      return .now { Latency.emit(mark) }
    case .playCue(let cue):
      return .now { services.playCue(cue) }
    case .save(let entry):
      return .recording { await services.save(entry) }
    case .keepRecording(let id, let samples):
      return .recording { await services.recordings.keep(id, samples) }
    case .discardRecording(let id):
      return .recording { await services.recordings.discard(id) }
    case .failRecording(let id, let reason):
      return .recording { await services.recordings.fail(id, reason) }
    }
  }

  private static func event(for outcome: PasteOutcome, _ id: SessionID) -> DictationEvent {
    switch outcome {
    case .pasted(let target, let at): .pasted(id, target: target, at: at)
    case .needsManualPaste: .manualPasteNeeded(id, at: .now())
    case .failed(.accessibilityNotGranted): .failed(id, .pastePermissionDenied)
    case .failed(.keystrokeFailed): .failed(id, .pasteRuntimeError)
    }
  }

  private static func report(
    _ error: CaptureError, for id: SessionID, to inbox: AsyncStream<DictationEvent>.Continuation
  ) {
    guard let reason = reason(for: error) else { return }
    if reason != .microphonePermissionDenied {
      logger.error("Capture failed: \(String(describing: error), privacy: .public)")
    }
    inbox.yield(.failed(id, reason))
  }

  static func reason(for error: CaptureError) -> DictationFailureReason? {
    switch error {
    case .cancelled: nil
    case .microphonePermissionDenied: .microphonePermissionDenied
    case .noInputDevice: .captureError(.noInputDevice)
    case .startTimedOut: .captureError(.startTimedOut)
    case .stopTimedOut: .captureError(.stopTimedOut)
    case .deviceLost: .captureError(.deviceLost)
    case .captureFailed, .notRecording, .alreadyRecording: .captureError(.captureFailed)
    }
  }
}
