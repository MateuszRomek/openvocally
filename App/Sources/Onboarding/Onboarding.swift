import AVFoundation
import ApplicationServices
import Foundation
import Hotkeys

/// The first-run walkthrough. It shows once per device: the flag lives in this
/// bundle's UserDefaults, so Debug, Release and other apps never share it.
enum Onboarding {
  static let completedKey = "onboarding.completed"
  /// `-onboarding YES` replays it in Debug (`make onboarding`).
  static let forcedKey = "onboarding"
  static let windowID = "onboarding"

  /// A returning user who already granted both permissions never sees it.
  static func isNeeded(completed: Bool, forced: Bool, accessibilityGranted: Bool, microphoneGranted: Bool)
    -> Bool
  {
    if forced { return true }
    if completed { return false }
    return !(accessibilityGranted && microphoneGranted)
  }

  private static var forcedAtLaunch: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: forcedKey)
    #else
      false
    #endif
  }

  static let neededAtLaunch = isNeeded(
    completed: UserDefaults.standard.bool(forKey: completedKey),
    forced: forcedAtLaunch,
    accessibilityGranted: AXIsProcessTrusted(),
    microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
}

/// The steps in order. Back works until the try-it succeeds, and every choice can be changed
/// in Settings later.
enum OnboardingStep: Int, CaseIterable {
  case welcome
  case permissions
  case shortcut
  case model
  case tryIt

  func next(in steps: [OnboardingStep]) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: self), index + 1 < steps.count else { return nil }
    return steps[index + 1]
  }

  func previous(in steps: [OnboardingStep]) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: self), index > 0 else { return nil }
    return steps[index - 1]
  }

  /// `-onboardingStep shortcut` opens a Debug build on that step (`make onboarding STEP=shortcut`).
  static var first: OnboardingStep {
    #if DEBUG
      if let name = UserDefaults.standard.string(forKey: "onboardingStep"),
        let step = allCases.first(where: { "\($0)" == name })
      {
        return step
      }
    #endif
    return .welcome
  }

  /// What a step says before anything happens on it.
  var content: (symbol: String, title: String, message: String, button: String) {
    switch self {
    case .welcome:
      ("", "OpenVocally", "Dictate anywhere on your Mac.", "Get Started")
    case .permissions:
      ("lock.shield", "Allow two permissions", "So you can dictate into any app.", "Continue")
    case .shortcut:
      (
        "keyboard", "Two ways to dictate", "Press once to start and again to stop, or hold to talk.",
        "Continue"
      )
    case .model:
      ("cpu", "Speech model", "It runs on your Mac, even offline.", "Continue")
    case .tryIt:
      ("waveform", "Try it", "Dictate into the box below.", "Start Using OpenVocally")
    }
  }
}

/// How one of the user's shortcuts starts dictation, such as "Hold ⌥Space" or "Press ⌘D".
struct ShortcutCue: Equatable {
  let verb: String
  let keys: String
  init(_ trigger: HotkeyTrigger, toggles: Bool) {
    switch trigger {
    case .chord(let chord):
      verb = toggles ? "Press" : "Hold"
      keys = chord.label
    case .doubleTap(let key):
      verb = toggles ? "Double-tap" : "Double-tap and hold"
      keys = key.symbol
    case .hold(let key):
      verb = "Hold"
      keys = key.label
    }
  }
}

extension HotkeyBindings {
  /// The toggle first, since it leaves room to pause and think, then push to talk; either may be
  /// unset.
  var shortcutCues: [ShortcutCue] {
    var cues: [ShortcutCue] = []
    if let press = trigger(for: .toggle) { cues.append(ShortcutCue(press, toggles: true)) }
    if let hold = trigger(for: .pushToTalk) { cues.append(ShortcutCue(hold, toggles: false)) }
    return cues
  }

  /// The try-it step's one instruction, such as "Press ⌥D or hold ⌥Space, then speak."
  var speakInstruction: String {
    let phrases = shortcutCues.prefix(2).map { "\($0.verb.lowercased()) \($0.keys)" }
    guard !phrases.isEmpty else { return "Set a shortcut in Settings to dictate." }
    return phrases.joined(separator: " or ").capitalizedFirst + ", then speak."
  }
}
