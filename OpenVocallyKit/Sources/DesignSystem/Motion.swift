import SwiftUI

/// Named animations.
public enum Motion: String, CaseIterable, Sendable {
  /// The notch grows to a bigger footprint for anything but a key press: a result arriving, the
  /// pointer bringing it to another display.
  case grow
  /// The notch shrinks to a smaller footprint, or leaves. Critically damped, so the shape never
  /// dips inside the hardware notch.
  case shrink
  /// The notch resizes because of a key press. Under Reduce Motion it is instant: a key's
  /// feedback, the recording mark on a press included, never fades in.
  case keyboard
  /// Notch content changes within one footprint. Pair it with `.transition(.blurReplace)`.
  case content
  /// The notch's meter bars follow the microphone level. Decoration: the bars freeze under
  /// Reduce Motion.
  case meter
  /// A banner or row appearing in a window.
  case windowReveal
  /// A row or section opening in place.
  case windowUnfold
  /// A pressed control shrinks to `pressScale` and back. Under Reduce Motion it dims instead.
  case press
  /// A control confirms an action, such as Copy turning into a checkmark.
  case confirm
  /// The confirmation goes back, faster than it came.
  case confirmEnd
  /// A key cap appears or goes down while a shortcut is recorded. Pair it with
  /// `.transition(.opacity)`.
  case keyCap
  /// The first-run welcome: icon, title, tagline and button arrive one after another,
  /// `introStagger` apart.
  case onboardingIntro
  /// An onboarding step slides in from the trailing side (the leading side going back), and a step's content swaps in
  /// place, such as Try it turning into "You're all set".
  case onboardingStep
  /// The onboarding step that leaves. Faster than the one that arrives.
  case onboardingExit

  public var animation: Animation {
    switch self {
    case .grow: .spring(response: 0.3, dampingFraction: 0.9)
    case .shrink: .spring(response: 0.25, dampingFraction: 1)
    case .keyboard: .spring(response: 0.15, dampingFraction: 1)
    case .content: .smooth(duration: 0.3)
    case .meter: .linear(duration: 0.05)
    case .windowReveal: .timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    case .windowUnfold: .spring(response: 0.35, dampingFraction: 1)
    case .press: .timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    case .confirm: .spring(response: 0.2, dampingFraction: 1)
    case .confirmEnd: .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    case .keyCap: .timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    case .onboardingIntro: .spring(response: 0.45, dampingFraction: 0.86)
    case .onboardingStep: .spring(response: 0.42, dampingFraction: 0.9)
    case .onboardingExit: .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }
  }

  /// The Reduce Motion variant: a short crossfade for anything that carries meaning, nothing
  /// for decoration or for a key's feedback. Views that move or resize switch to an opacity transition with it.
  var reduced: Animation? {
    switch self {
    case .grow, .shrink, .content:
      .easeInOut(duration: 0.2)
    case .windowReveal, .windowUnfold: .easeOut(duration: 0.15)
    case .press: .easeOut(duration: 0.1)
    case .confirm, .confirmEnd: .easeInOut(duration: 0.15)
    case .keyCap: .easeOut(duration: 0.1)
    case .onboardingIntro, .onboardingStep: .easeInOut(duration: 0.2)
    case .onboardingExit: .easeOut(duration: 0.15)
    case .meter, .keyboard: nil
    }
  }

  public func resolved(reduceMotion: Bool) -> Animation? {
    reduceMotion ? reduced : animation
  }

  static let pressScale: CGFloat = 0.97
  /// How dim `press` makes a control under Reduce Motion.
  static let pressDim: Double = 0.6
  /// How long a confirmation such as Copied stays before `confirmEnd`.
  static let confirmationHold: Duration = .seconds(1.2)
  /// How much faster than the system default a confirming symbol swap plays.
  static let symbolSpeed: Double = 1.5
  /// The gap between the welcome's elements under `onboardingIntro`.
  public static let introStagger: Double = 0.07
  /// How far an onboarding step travels as it enters or leaves.
  static let stepTravel: CGFloat = 20
  /// Entrances start this close to full size, never from nothing.
  static let appearScale: CGFloat = 0.9

  /// A badge that confirms a new state, such as the Active tag on the model just picked: it
  /// sharpens in from slightly small on `confirm` and leaves with a plain fade, faster than it
  /// came. A crossfade under Reduce Motion.
  @MainActor public static func confirmEntrance(reduceMotion: Bool) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: AnyTransition(.blurReplace).combined(with: .scale(scale: Motion.appearScale)),
      removal: AnyTransition.opacity.animation(Motion.confirmEnd.animation))
  }

  public enum StepDirection: Sendable {
    case forward
    case backward
  }

  /// An onboarding step: forward it enters from the trailing side with a light blur and the old
  /// step leaves to the leading side on the faster `onboardingExit`; backward mirrors both.
  /// A crossfade under Reduce Motion.
  @MainActor public static func stepTransition(_ direction: StepDirection, reduceMotion: Bool)
    -> AnyTransition
  {
    guard !reduceMotion else { return .opacity }
    let travel = direction == .forward ? stepTravel : -stepTravel
    return .asymmetric(
      insertion: AnyTransition(.blurReplace).combined(with: .offset(x: travel)),
      removal: AnyTransition(.blurReplace).combined(with: .offset(x: -travel))
        .animation(Motion.onboardingExit.animation))
  }
}

extension View {
  /// `animation(_:value:)` with the token's Reduce Motion variant when the setting is on.
  public func motion(_ motion: Motion, value: some Equatable) -> some View {
    modifier(MotionModifier(motion: motion, value: value))
  }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
  let motion: Motion
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(motion.resolved(reduceMotion: reduceMotion), value: value)
  }
}
