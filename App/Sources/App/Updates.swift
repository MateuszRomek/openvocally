import AppKit
import Foundation
import Observation
import Sparkle
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "updates")

/// Sparkle's updater, present only in builds whose Info.plist names a feed and a public key. Release builds get
/// one from the release script; source builds leave the feed empty and never touch the network.
///
/// A scheduled check never opens a window on its own: a window that takes focus mid-dictation
/// would receive the paste. Updates surface as `state`, and the user opens them from there.
@MainActor @Observable final class Updates {
  enum State: Equatable {
    case none
    /// A scheduled check found an update Sparkle could not install silently.
    case available(version: String)
    /// Downloaded and staged. It installs on quit, or now with `installNow()`.
    case readyToInstall(version: String)
  }

  private(set) var state = State.none
  private(set) var canCheckForUpdates = false
  var automaticallyChecks = false {
    didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
  }
  var automaticallyInstalls = false {
    didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstalls }
  }

  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var delegate: UpdaterDelegate?
  @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
  @ObservationIgnored private var installImmediately: (() -> Void)?

  init(bundle: Bundle = .main) {
    let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
    let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    guard !feed.isEmpty, !publicKey.isEmpty else {
      let missing = feed.isEmpty ? "SUFeedURL" : "SUPublicEDKey"
      logger.info("Updates are off: the Info.plist has no \(missing, privacy: .public)")
      return
    }
    let delegate = UpdaterDelegate()
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
    self.delegate = delegate
    self.controller = controller
    delegate.updates = self
    controller.startUpdater()
    automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
    canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
    }
  }

  var isAvailable: Bool { controller != nil }

  func checkForUpdates() {
    NSApp.activate()
    controller?.checkForUpdates(nil)
  }

  /// Installs the staged update and relaunches.
  func installNow() {
    installImmediately?()
  }

  /// Brings Sparkle's window for the found update into focus, because the user asked for it.
  func showAvailableUpdate() {
    checkForUpdates()
  }

  fileprivate func readyToInstall(version: String, install: @escaping () -> Void) {
    installImmediately = install
    state = .readyToInstall(version: version)
    logger.notice("Update ready to install: \(version, privacy: .public)")
  }

  fileprivate func found(version: String) {
    guard case .none = state else { return }
    state = .available(version: version)
    logger.notice("Update available: \(version, privacy: .public)")
  }

  fileprivate func dismissAvailable() {
    if case .available = state { state = .none }
  }
}

/// Sparkle's delegates must be NSObjects, so this forwards to `Updates`.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  weak var updates: Updates?

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    updates?.readyToInstall(version: item.displayVersionString, install: immediateInstallHandler)
    return true
  }

  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    guard !handleShowingUpdate else { return }
    let version = update.displayVersionString
    MainActor.assumeIsolated { updates?.found(version: version) }
  }

  nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    MainActor.assumeIsolated { updates?.dismissAvailable() }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated { updates?.dismissAvailable() }
  }
}
