import DesignSystem
import Models
import SwiftUI
import Transcription

/// The one model onboarding offers: Parakeet v3, or the model already installed.
struct ModelSetupCard: View {
  let library: ModelLibrary
  let status: ModelDownloadStatus

  private var shown: ModelID {
    library.installed.contains(library.active) ? library.active : .parakeetV3
  }

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Space.m.points) {
        HStack(alignment: .firstTextBaseline) {
          Text(shown.name).textStyle(.headline)
          Spacer(minLength: Space.s.points)
          if let hosted = shown.downloadable {
            Tag(hosted.manifest.totalBytes.formatted(.byteCount(style: .file)))
          }
        }
        Text(shown.summary)
          .textStyle(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        state
      }
    }
    .frame(maxWidth: StepHeader.textWidth)
  }

  @ViewBuilder private var state: some View {
    if shown == ModelDownloadStatus.model, status != .hidden, status != .ready {
      if case .downloading(let fraction) = status {
        ProgressView(value: fraction ?? 0)
        HStack {
          Text("We started this download for you.")
          Spacer(minLength: Space.s.points)
          Text(fraction ?? 0, format: .percent.precision(.fractionLength(0))).monospacedDigit()
        }
        .textStyle(.callout)
        .foregroundStyle(.secondary)
      } else {
        ModelDownloadStatusLine(status: status) { library.startDownload(shown) }
      }
    } else if library.installed.contains(shown) {
      StatusRow(
        title: library.runtime == .ready ? "Ready" : "Getting ready",
        detail: library.runtime == .ready ? "Dictation works offline" : "Loading the model",
        status: library.runtime == .ready ? .ok : .progress)
    } else {
      Button("Download") { library.startDownload(shown) }.appButton(size: .small)
    }
  }
}
