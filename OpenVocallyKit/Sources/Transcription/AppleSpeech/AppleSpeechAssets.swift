import Foundation
import Models
import Speech
import os

/// Speech assets through AssetInventory: macOS downloads, stores and evicts them.
@available(macOS 26, *)
struct AppleSpeechAssets: SystemModelStore {
  func isAvailable(_ model: SystemModel) -> Bool {
    switch model {
    case .dictation: true
    case .speech: SpeechTranscriber.isAvailable
    }
  }

  func supportedLocales(_ model: SystemModel) async -> [Locale] {
    await SpeechModuleSession.supportedLocales(model)
  }

  func isInstalled(_ model: SystemModel, locale: Locale) async -> Bool {
    await AssetInventory.status(forModules: [SpeechModuleSession(model, locale: locale).module])
      == .installed
  }

  func install(
    _ model: SystemModel, locale: Locale, progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws(DownloadError) {
    let module = SpeechModuleSession(model, locale: locale).module
    try await Self.reserve(locale)
    do {
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
        return
      }
      transcriptionLogger.notice(
        "Speech assets install started: \(model.rawValue, privacy: .public), \(locale.identifier, privacy: .public)"
      )
      // Progress reports through KVO; polling it keeps the reporting on this task.
      let reporter = Task {
        while !Task.isCancelled {
          let units = request.progress
          progress(
            units.totalUnitCount > 0
              ? .downloading(received: units.completedUnitCount, total: units.totalUnitCount)
              : .indeterminate)
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
      defer { reporter.cancel() }
      try await withTaskCancellationHandler {
        try await request.downloadAndInstall()
      } onCancel: {
        request.progress.cancel()
      }
      if Task.isCancelled { throw CancellationError() }
      transcriptionLogger.notice("Speech assets installed: \(model.rawValue, privacy: .public)")
    } catch {
      transcriptionLogger.notice(
        "Speech assets install ended: \(model.rawValue, privacy: .public), \(String(describing: error), privacy: .public)"
      )
      throw Self.downloadError(error)
    }
  }

  func release(_ locale: Locale) async {
    await AssetInventory.release(reservedLocale: locale)
  }

  /// A reservation counts against `maximumReservedLocales`, so a full set is reported as such
  /// rather than as a failed install.
  private static func reserve(_ locale: Locale) async throws(DownloadError) {
    let reserved = await AssetInventory.reservedLocales
    guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
    guard reserved.count < AssetInventory.maximumReservedLocales else { throw .reservationLimit }
    do {
      try await AssetInventory.reserve(locale: locale)
    } catch {
      transcriptionLogger.notice(
        "Speech locale not reserved: \(locale.identifier, privacy: .public), \(String(describing: error), privacy: .public)"
      )
      throw await AssetInventory.reservedLocales.count >= AssetInventory.maximumReservedLocales
        ? .reservationLimit : downloadError(error)
    }
  }

  static func downloadError(_ error: any Error) -> DownloadError {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    if (error as NSError).domain == NSURLErrorDomain { return .offline }
    return .fileSystem
  }
}
