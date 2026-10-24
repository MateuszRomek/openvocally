import DesignSystem
import Models
import SwiftUI
import Transcription

/// The onboarding's speech-model download, as one state for every step to show.
enum ModelDownloadStatus: Equatable {
  case hidden
  /// `fraction` is nil before the first bytes and while verifying.
  case downloading(fraction: Double?)
  case ready
  case offline
  case failed

  static let model = ModelID.parakeetV3

  /// `waiting`: Get Started was pressed offline, so the download waits for a connection.
  /// `justFinished`: it finished during onboarding and the confirmation is still showing.
  /// `online`: the network path, nil before the first reading. A transport error while the
  /// Mac is online, such as a timeout, is a failure with Try Again, not "offline".
  @MainActor init(library: ModelLibrary, waiting: Bool, justFinished: Bool, online: Bool?) {
    let state = library.state(of: Self.model)
    if case .installing(let progress) = state.readiness {
      self = .downloading(fraction: progress.fraction)
    } else if waiting || (state.failure == .download(.offline) && online == false) {
      self = .offline
    } else if state.failure != nil {
      self = .failed
    } else if justFinished {
      self = .ready
    } else {
      self = .hidden
    }
  }

  var title: String {
    switch self {
    case .hidden: ""
    case .downloading(let fraction?):
      "Downloading your speech model · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    case .downloading: "Downloading your speech model"
    case .ready: "Speech model ready"
    case .offline: "You're offline. The model downloads when you reconnect."
    case .failed: "Couldn't download the speech model."
    }
  }

  var icon: Status {
    switch self {
    case .hidden, .downloading: .progress
    case .ready: .ok
    case .offline, .failed: .attention
    }
  }
}

struct ModelDownloadStatusLine: View {
  let status: ModelDownloadStatus
  let retry: () -> Void

  var body: some View {
    Group {
      if status != .hidden {
        content
          .id(Phase(status))
          .transition(.blurReplace)
      }
    }
    .motion(.confirm, value: Phase(status))
  }

  @ViewBuilder private var content: some View {
    HStack(spacing: Space.s.points) {
      StatusIcon(status.icon)
      Text(status.title)
        .textStyle(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      if status == .failed {
        Button("Try Again", action: retry).appButton(size: .small)
      }
    }
  }

  /// The percent changes in place; only a change of state cross-blurs.
  private enum Phase: Hashable {
    case hidden, downloading, ready, offline, failed

    init(_ status: ModelDownloadStatus) {
      self =
        switch status {
        case .hidden: .hidden
        case .downloading: .downloading
        case .ready: .ready
        case .offline: .offline
        case .failed: .failed
        }
    }
  }
}
