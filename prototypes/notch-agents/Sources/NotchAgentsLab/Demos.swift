import SwiftUI

/// One click in the control window: it resets the scene, sets the signal options, and plays a
/// sequence, so each option can be judged on its own without touching the pickers.
struct SignalDemo: Identifiable {
  let group: String
  let title: String
  /// What to look at while it plays.
  let watch: String
  let scenario: Lab.Scenario
  let setup: (Lab) -> Void

  var id: String { group + title }

  static let groups = ["Working, closed", "Needs you arrives", "Unseen Done", "Failed", "Together"]

  static let all: [SignalDemo] = [
    SignalDemo(
      group: "Working, closed", title: "Nothing",
      watch: "Two threads work for about 12 s and the notch stays hidden. Hover it midway: the peek says 2 threads working. Then Done arrives.",
      scenario: .working) { $0.ambient = .nothing },
    SignalDemo(
      group: "Working, closed", title: "Thin lip",
      watch: "The notch drops 5 pt below the camera while threads work, with a faint light drifting along the lip.",
      scenario: .working) { $0.ambient = .lip },
    SignalDemo(
      group: "Working, closed", title: "Still dot",
      watch: "The wings come out with the provider glyph, dimmed, and a still dot with the count.",
      scenario: .working) { $0.ambient = .stillDot },
    SignalDemo(
      group: "Working, closed", title: "Breathing dot",
      watch: "Like the still dot, but it breathes every 2.4 s.",
      scenario: .working) { $0.ambient = .breathingDot },

    SignalDemo(
      group: "Needs you arrives", title: "Grow only",
      watch: "The orange mark appears as the shape grows. Nothing else.",
      scenario: .quickNeeds) {
        $0.arrival = .mark
        $0.attentionArrival = .grow
      },
    SignalDemo(
      group: "Needs you arrives", title: "Soft glow",
      watch: "Once the shape has grown, an orange halo brightens on its edge and fades over about a second.",
      scenario: .quickNeeds) {
        $0.arrival = .mark
        $0.attentionArrival = .glow
      },
    SignalDemo(
      group: "Needs you arrives", title: "Dot pulses",
      watch: "The orange dot swells twice, then holds.",
      scenario: .quickNeeds) {
        $0.arrival = .mark
        $0.attentionArrival = .pulse
      },
    SignalDemo(
      group: "Needs you arrives", title: "Card + glow",
      watch: "The decided approval card grows under the notch, and the glow plays on the card's edge.",
      scenario: .quickNeeds) {
        $0.arrival = .card
        $0.attentionArrival = .glow
      },

    SignalDemo(
      group: "Unseen Done", title: "Gray check",
      watch: "A gray check and Done. It stays until you peek or open the thread.",
      scenario: .quickDone) { $0.doneMark = .check },
    SignalDemo(
      group: "Unseen Done", title: "White dot",
      watch: "A white dot and Done: news, in the chrome's own ink.",
      scenario: .quickDone) { $0.doneMark = .dot },
    SignalDemo(
      group: "Unseen Done", title: "One glint",
      watch: "A gray check and Done, with one light sweep across them as they arrive.",
      scenario: .quickDone) { $0.doneMark = .glint },

    SignalDemo(
      group: "Failed", title: "Orange",
      watch: "Failed in the same orange as Needs you.",
      scenario: .quickFailed) { $0.failedTint = .orange },
    SignalDemo(
      group: "Failed", title: "Red",
      watch: "Failed in red, as the design system's failed status.",
      scenario: .quickFailed) { $0.failedTint = .red },
    SignalDemo(
      group: "Failed", title: "White",
      watch: "Failed in white with a cross: no hue at all.",
      scenario: .quickFailed) { $0.failedTint = .white },

    SignalDemo(
      group: "Together", title: "Done, Failed, Needs you",
      watch: "Done, then Failed 4 s later, then Needs you, which takes the front with a badge of 3. Uses the current Signals picks.",
      scenario: .signals) { $0.arrival = .mark },
    SignalDemo(
      group: "Together", title: "While dictating",
      watch: "Dictation records for 6 s while all three arrive. Nothing shows until Pasted is gone, then Needs you arrives with its signal.",
      scenario: .duringDictation) { $0.arrival = .mark },
    SignalDemo(
      group: "Together", title: "Reduce Motion",
      watch: "The same three with Reduce Motion: crossfades instead of springs, no pulse or glint. The glow stays, because it's light, not movement.",
      scenario: .signals) {
        $0.arrival = .mark
        $0.reduceMotion = true
      },
    SignalDemo(
      group: "Together", title: "Reduce Motion, lip",
      watch: "The lip with Reduce Motion: its light holds still.",
      scenario: .working) {
        $0.ambient = .lip
        $0.reduceMotion = true
      },
  ]
}

extension Lab {
  /// Applies a demo on top of the decided defaults, so demos never inherit each other's picks,
  /// except Together's first two, which keep your Signals picks to try combinations.
  func run(_ demo: SignalDemo) {
    reset()
    if demo.group != "Together" || demo.title.hasPrefix("Reduce") {
      ambient = .nothing
      attentionArrival = .glow
      doneMark = .check
      failedTint = .red
    }
    arrival = .card
    reduceMotion = false
    demo.setup(self)
    nowShowing = demo.id
    Task {
      // Lets the reset settle so the demo starts from a hidden notch.
      try? await Task.sleep(for: .seconds(0.6))
      play(demo.scenario)
    }
  }
}
