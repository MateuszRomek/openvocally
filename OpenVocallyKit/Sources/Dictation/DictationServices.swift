import AudioCapture
import DictationCore
import Paste
import Transcription

/// The outside world as closures, so tests drive the real pipeline with fakes.
public struct DictationServices: Sendable {
  public var commands: AsyncStream<StampedCommand>
  public var phaseDidChange: @Sendable (DictationPhase) -> Void
  /// The closure reports a failure after the start returned, such as the mic vanishing mid-recording.
  public var startCapture:
    @Sendable (HostTime, @escaping @Sendable (CaptureError) -> Void) async throws(CaptureError) -> Void
  public var stopCapture: @Sendable (HostTime) async throws(CaptureError) -> [Float]
  public var cancelCapture: @Sendable () async -> Void
  public var transcribe: @Sendable ([Float]) async throws(TranscriptionError) -> String
  var processor: TextProcessor
  public var paste: @Sendable (Transcript, PasteKind) async -> PasteOutcome
  public var completeManualPaste: @Sendable () async -> ManualPasteResult
  public var abandonManualPaste: @Sendable () async -> Void
  public var sleep: @Sendable (Duration) async -> Void
  public var playCue: @Sendable (SoundCue) -> Void
  public var save: @Sendable (DictationEntry) async -> Void
  var recordings: RecordingSink

  public init(
    commands: AsyncStream<StampedCommand>,
    phaseDidChange: @escaping @Sendable (DictationPhase) -> Void,
    startCapture:
      @escaping @Sendable (HostTime, @escaping @Sendable (CaptureError) -> Void) async throws(CaptureError) ->
      Void,
    stopCapture: @escaping @Sendable (HostTime) async throws(CaptureError) -> [Float],
    cancelCapture: @escaping @Sendable () async -> Void,
    transcribe: @escaping @Sendable ([Float]) async throws(TranscriptionError) -> String,
    processor: TextProcessor,
    paste: @escaping @Sendable (Transcript, PasteKind) async -> PasteOutcome,
    completeManualPaste: @escaping @Sendable () async -> ManualPasteResult = { .ended },
    abandonManualPaste: @escaping @Sendable () async -> Void = {},
    sleep: @escaping @Sendable (Duration) async -> Void,
    playCue: @escaping @Sendable (SoundCue) -> Void = { _ in },
    save: @escaping @Sendable (DictationEntry) async -> Void = { _ in },
    recordings: RecordingSink = .none
  ) {
    self.commands = commands
    self.phaseDidChange = phaseDidChange
    self.startCapture = startCapture
    self.stopCapture = stopCapture
    self.cancelCapture = cancelCapture
    self.transcribe = transcribe
    self.processor = processor
    self.paste = paste
    self.completeManualPaste = completeManualPaste
    self.abandonManualPaste = abandonManualPaste
    self.sleep = sleep
    self.playCue = playCue
    self.save = save
    self.recordings = recordings
  }

  public static func live(
    commands: AsyncStream<StampedCommand>, phaseDidChange: @escaping @Sendable (DictationPhase) -> Void,
    capture: AudioCapture, runtime: TranscriptionRuntime, paster: Paster,
    processor: TextProcessor = .passThrough, playCue: @escaping @Sendable (SoundCue) -> Void,
    save: @escaping @Sendable (DictationEntry) async -> Void = { _ in }, recordings: RecordingSink = .none
  ) -> DictationServices {
    DictationServices(
      commands: commands,
      phaseDidChange: phaseDidChange,
      startCapture: { (at, onInterrupted) throws(CaptureError) in
        await runtime.warm(listening: { await capture.recordingSoFar() })
        do throws(CaptureError) {
          _ = try await capture.start(pressedAt: at, onInterrupted: onInterrupted)
        } catch {
          await runtime.coolDown()
          throw error
        }
      },
      stopCapture: { (at) throws(CaptureError) in
        do throws(CaptureError) {
          return try await capture.stop(releasedAt: at).samples
        } catch {
          await runtime.coolDown()
          throw error
        }
      },
      cancelCapture: {
        await runtime.coolDown()
        await capture.cancel()
      },
      transcribe: { (samples) throws(TranscriptionError) in try await runtime.transcribe(samples) },
      processor: processor,
      paste: { await paster.paste($0, kind: $1) },
      completeManualPaste: { await paster.completeManualPaste() },
      abandonManualPaste: { await paster.abandonManualPaste() },
      sleep: { try? await Task.sleep(for: $0) },
      playCue: playCue,
      save: save,
      recordings: recordings
    )
  }
}
