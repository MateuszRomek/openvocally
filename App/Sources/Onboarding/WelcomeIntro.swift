import AppKit
import DesignSystem
import SwiftUI

/// The first screen: the app icon, the name and a tagline arriving one after another.
struct WelcomeIntro: View {
  @State private var shown = false

  var body: some View {
    VStack(spacing: Space.l.points) {
      Spacer(minLength: 0)
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: Self.iconSize, height: Self.iconSize)
        .accessibilityHidden(true)
        .modifier(IntroItem(index: 0, shown: shown, grows: true))
      VStack(spacing: Space.s.points) {
        Text("OpenVocally")
          .textStyle(.largeTitle)
          .fontWeight(.bold)
          .modifier(IntroItem(index: 1, shown: shown))
        Text(OnboardingStep.welcome.content.message)
          .textStyle(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .modifier(IntroItem(index: 2, shown: shown))
      }
      Spacer(minLength: 0)
    }
    .onAppear { shown = true }
  }

  static let iconSize: CGFloat = 96
}

/// One element of the welcome's entrance: it fades in, sharpens and settles into place,
/// `Motion.introStagger` after the one before. A plain fade under Reduce Motion.
private struct IntroItem: ViewModifier {
  let index: Int
  let shown: Bool
  var grows = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let settled = shown || reduceMotion
    content
      .opacity(shown ? 1 : 0)
      .scaleEffect(settled || !grows ? 1 : Self.startScale)
      .offset(y: settled || grows ? 0 : Self.rise)
      .blur(radius: settled ? 0 : Self.blur)
      .animation(
        Motion.onboardingIntro.resolved(reduceMotion: reduceMotion)?.delay(
          Double(index) * Motion.introStagger),
        value: shown)
  }

  static let startScale: CGFloat = 0.9
  static let rise: CGFloat = 8
  static let blur: CGFloat = 4
}
