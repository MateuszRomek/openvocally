import DesignSystem
import Dictation
import DictationCore
import Hotkeys
import SwiftUI

/// One key pressed and released alone on the push-to-talk row, waiting for Use this.
struct HoldOffer: Equatable {
  let key: HoldKey
  /// Shown before saving, such as Right ⌥ on a layout that types letters with it.
  let warning: HoldKeyWarning?
}

/// The keys held right now while a shortcut is recorded, with their side. A blank cap stands
/// in before the first key goes down.
struct HeldKeyCaps: View {
  let held: HeldKeys

  var body: some View {
    HStack(spacing: Space.xs.points) {
      if held.keys.isEmpty {
        KeyCap("")
          .transition(.opacity)
      }
      ForEach(held.keys, id: \.self) { key in
        KeyCap(key.label)
          .accessibilityLabel(key.name)
          .transition(.opacity)
      }
    }
    .motion(.keyCap, value: held)
  }
}

/// "Hold Right ⌘ to talk." The key is live for a trial while the card shows: holding it records
/// through the real tap and pipeline but never pastes, and the transcript shows here and nowhere
/// else. One primary action saves; Pick another goes back to listening.
struct HoldOfferCard: View {
  let offer: HoldOffer
  let trial: HoldTrial?
  let error: String?
  let useIt: () -> Void
  let pickAnother: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Space.s.points) {
      Text("Hold \(offer.key.label) to talk.")
        .textStyle(.headline)
      if let warning = offer.warning {
        notice(warning.message)
      }
      if let trial {
        trialView(trial)
          .transition(.opacity)
      }
      if let error {
        notice(error)
      }
      HStack(spacing: Space.s.points) {
        Button("Pick another", action: pickAnother)
          .appButton(.quiet)
        Spacer()
        Button("Use \(offer.key.label)", action: useIt)
          .appButton(.primary)
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Space.m)
    .surface(.card, in: Radius.card.shape)
    .motion(.keyCap, value: trialStage)
  }

  private func notice(_ text: String) -> some View {
    Label {
      Text(text)
    } icon: {
      StatusIcon(.attention)
    }
    .textStyle(.callout)
  }

  @ViewBuilder private func trialView(_ trial: HoldTrial) -> some View {
    switch trial {
    case .waiting:
      Text("Try it: hold \(offer.key.label) and say something. Nothing is pasted.")
        .foregroundStyle(.secondary)
    case .listening(let level):
      ProgressView(value: Double(min(max(level, 0), 1)))
        .progressViewStyle(.linear)
        .accessibilityLabel("Microphone level")
    case .heard(let text):
      Text(text)
        .textSelection(.enabled)
    case .failed(let reason):
      notice(reason.trialMessage)
    }
  }

  /// Changes once per stage, not per level tick, so the meter itself never animates.
  private var trialStage: Int {
    switch trial {
    case nil: 0
    case .waiting: 1
    case .listening: 2
    case .heard: 3
    case .failed: 4
    }
  }
}

extension DictationFailureReason {
  var trialMessage: String {
    switch self {
    case .noSpeech: "Didn't hear anything. Hold the key and speak."
    case .modelNotInstalled: "Download a speech model first."
    case .microphonePermissionDenied: "Allow the microphone above first."
    default: "Couldn't transcribe that. Try again."
    }
  }
}
