import SwiftUI

/// What a button does, which sets its weight. Each case wraps a system style, so buttons keep
/// the native press, focus and Liquid Glass behavior.
public enum ButtonVariant: String, CaseIterable, Sendable {
  /// The one action a screen is for. At most one per view.
  case primary
  case secondary
  /// Inline actions in rows and banners, without a bezel.
  case quiet
  /// Deletes or discards something the user can't get back.
  case destructive
  /// A whole card the user picks, such as an option with a preview. No bezel; the card
  /// shrinks to `Motion.pressScale` on press, or dims under Reduce Motion.
  case card
}

/// The window default is `regular`; `small` fits rows and banners.
public enum ControlScale: String, CaseIterable, Sendable {
  case small
  case regular
  case large

  public var controlSize: ControlSize {
    switch self {
    case .small: .small
    case .regular: .regular
    case .large: .large
    }
  }
}

extension View {
  public func appButton(_ variant: ButtonVariant = .secondary, size: ControlScale = .regular)
    -> some View
  {
    modifier(AppButtonModifier(variant: variant)).controlSize(size.controlSize)
  }
}

private struct AppButtonModifier: ViewModifier {
  let variant: ButtonVariant

  @ViewBuilder func body(content: Content) -> some View {
    switch variant {
    case .primary: content.buttonStyle(.borderedProminent).tint(.token(.accent))
    case .secondary: content.buttonStyle(.bordered)
    case .quiet: content.buttonStyle(.borderless)
    case .destructive: content.buttonStyle(.borderedProminent).tint(.token(.destructive))
    case .card: content.buttonStyle(CardPressStyle())
    }
  }
}

private struct CardPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    configuration.label
      .scaleEffect(pressed && !reduceMotion ? Motion.pressScale : 1)
      .opacity(pressed && reduceMotion ? Motion.pressDim : 1)
      .animation(Motion.press.resolved(reduceMotion: reduceMotion), value: pressed)
  }
}

/// A borderless button that answers the press at once: it shrinks to `Motion.pressScale`, or dims
/// under Reduce Motion.
struct PressFeedbackStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    configuration.label
      .padding(.xxs)
      .contentShape(.rect)
      .scaleEffect(pressed && !reduceMotion ? Motion.pressScale : 1)
      .opacity(pressed && reduceMotion ? Motion.pressDim : 1)
      .animation(Motion.press.resolved(reduceMotion: reduceMotion), value: pressed)
  }
}
