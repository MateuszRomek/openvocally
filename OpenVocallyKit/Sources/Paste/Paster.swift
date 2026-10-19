import AppKit
import ApplicationServices
import DictationCore
import os

private let latencySignposter = OSSignposter(subsystem: "com.openvocally.app", category: "latency")

public enum PasteFailure: Error, Sendable, Equatable {
  case accessibilityNotGranted
  /// Both attempts failed to build the Cmd+V events.
  case keystrokeFailed
}

public enum PasteOutcome: Sendable, Equatable {
  /// `at` is when the Cmd+V key-down was posted, the end of LB-02.
  case pasted(target: TargetApp?, at: HostTime)
  /// Dictation only: no text field took the paste, so the transcript stays on the clipboard
  /// for the user's own ⌘V. Finish with `completeManualPaste` or `abandonManualPaste`.
  case needsManualPaste
  case failed(PasteFailure)
}

public enum ManualPasteResult: Sendable, Equatable {
  /// The clipboard is restored 900 ms later.
  case pasted(target: TargetApp?)
  /// Focus was still outside a text field, so the window stays open.
  case notInTextField
  /// The window is over: it already closed, or someone copied since our write, so that ⌘V
  /// pasted their copy.
  case ended
}

public enum PasteKind: Sendable {
  case dictation
  case pasteLast

  var restoreDelay: Duration {
    switch self {
    case .dictation: .milliseconds(420)
    case .pasteLast: .milliseconds(700)
    }
  }
}

private let logger = Logger(subsystem: "com.openvocally.app", category: "paste")

/// Pastes through the clipboard and restores it afterwards. One paste at a time; a new paste
/// first completes the previous one's pending restore.
public actor Paster {
  static let retryDelay: Duration = .milliseconds(200)

  private let pasteboard: any Pasteboard
  private let keystroke: any PasteKeystroke
  private let isTrusted: @Sendable () -> Bool
  private let frontmostApp: @Sendable () -> TargetApp?
  private let sleep: @Sendable (Duration) async -> Void
  static let manualRestoreDelay: Duration = .milliseconds(900)

  private let focusedField: @Sendable () -> FocusedField
  /// Open from our first write until its restore, so a quit mid-paste still restores.
  private var open: ClipboardTransaction?
  /// Set while `open` waits for the user's ⌘V.
  private var awaitingManualPaste = false
  private var restoreTimer: Task<Void, Never>?

  public init() {
    self.init(
      pasteboard: SystemPasteboard(),
      keystroke: CGPasteKeystroke(),
      isTrusted: { AXIsProcessTrusted() },
      frontmostApp: {
        NSWorkspace.shared.frontmostApplication.map {
          TargetApp(name: $0.localizedName, bundleIdentifier: $0.bundleIdentifier)
        }
      },
      focusedField: { FocusedField(FocusProbe.read()) },
      sleep: { try? await Task.sleep(for: $0) }
    )
  }

  init(
    pasteboard: some Pasteboard, keystroke: some PasteKeystroke,
    isTrusted: @escaping @Sendable () -> Bool,
    frontmostApp: @escaping @Sendable () -> TargetApp?,
    focusedField: @escaping @Sendable () -> FocusedField = { .unknown },
    sleep: @escaping @Sendable (Duration) async -> Void
  ) {
    self.focusedField = focusedField
    self.pasteboard = pasteboard
    self.keystroke = keystroke
    self.isTrusted = isTrusted
    self.frontmostApp = frontmostApp
    self.sleep = sleep
  }

  public func paste(_ transcript: Transcript, kind: PasteKind = .dictation) async -> PasteOutcome {
    let start = HostTime.now()
    guard isTrusted() else { return .failed(.accessibilityNotGranted) }
    flushPendingRestore()
    let target = frontmostApp()
    open = ClipboardTransaction.begin(on: pasteboard, writing: transcript.text)
    if kind == .dictation, focusedField() == .noTextField {
      awaitingManualPaste = true
      return .needsManualPaste
    }
    var keyStart = HostTime.now()
    if kind == .dictation {
      let ms = keyStart.milliseconds(since: start)
      latencySignposter.emitEvent(
        "LB-02-pasteSetup", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
    }
    for attempt in 1...2 {
      if attempt == 2 {
        await sleep(Self.retryDelay)
        keyStart = HostTime.now()
        guard var transaction = open else { return .failed(.keystrokeFailed) }
        guard transaction.rewrite(on: pasteboard) else {
          open = nil
          return .failed(.keystrokeFailed)
        }
        open = transaction
      }
      if let at = await keystroke.postCommandV() {
        if kind == .dictation {
          let ms = at.milliseconds(since: keyStart)
          latencySignposter.emitEvent(
            "LB-02-keyPost", "ms=\(ms, format: .fixed(precision: 2), privacy: .public)")
        }
        scheduleRestore(after: kind.restoreDelay)
        return .pasted(target: target, at: at)
      }
      logger.error("Cmd+V attempt \(attempt, privacy: .public) failed")
    }
    if kind == .dictation, open != nil {
      awaitingManualPaste = true
      return .needsManualPaste
    }
    flushPendingRestore()
    return .failed(.keystrokeFailed)
  }

  /// The user pressed ⌘V in the manual paste window. The keystroke already reached the app.
  public func completeManualPaste() -> ManualPasteResult {
    guard awaitingManualPaste, let transaction = open else { return .ended }
    guard transaction.isCurrent(on: pasteboard) else {
      awaitingManualPaste = false
      open = nil
      return .ended
    }
    if focusedField() == .noTextField { return .notInTextField }
    awaitingManualPaste = false
    scheduleRestore(after: Self.manualRestoreDelay)
    return .pasted(target: frontmostApp())
  }

  /// Closes the manual paste window without a paste and restores the clipboard now.
  public func abandonManualPaste() {
    guard awaitingManualPaste else { return }
    flushPendingRestore()
  }

  /// Restores the open transaction now, whether its paste is still in flight or its timer
  /// is pending. The app calls it on quit.
  public func flushPendingRestore() {
    awaitingManualPaste = false
    restoreTimer?.cancel()
    restoreTimer = nil
    guard let transaction = open else { return }
    open = nil
    if transaction.restore(on: pasteboard) == .skippedBecauseChanged {
      logger.notice("Clipboard changed after the paste; restore skipped")
    }
  }

  /// Test hook: waits until a scheduled restore has run or been flushed.
  func waitForPendingRestore() async {
    await restoreTimer?.value
  }

  private func scheduleRestore(after delay: Duration) {
    guard let transaction = open else { return }
    let sleep = self.sleep
    restoreTimer = Task {
      await sleep(delay)
      guard !Task.isCancelled else { return }
      self.restoreIfOpen(transaction)
    }
  }

  private func restoreIfOpen(_ transaction: ClipboardTransaction) {
    // Each write gets a fresh change count, so it identifies the transaction.
    guard open?.ownedChangeCount == transaction.ownedChangeCount else { return }
    restoreTimer = nil
    flushPendingRestore()
  }
}
