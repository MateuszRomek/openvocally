import SwiftUI

/// What fills a whole window behind its content. The user picks it in Settings.
public enum WindowBackground: String, CaseIterable, Sendable {
  /// The standard opaque window background.
  case solid
  /// A behind-window material, so the desktop shows through blurred, like Craft. Lists
  /// and forms drop their own backgrounds so the material reads as one surface. The toolbar
  /// keeps its automatic background, the scroll edge effect, so content fades out under the
  /// title instead of overlapping it. Reduce Transparency turns it opaque, which the system
  /// applies.
  case translucent
}

extension View {
  /// Fills the window this view's scene presents with the given background. Both cases apply
  /// the same modifiers with different values, so switching keeps the view tree, and with it
  /// scroll positions and focus.
  public func windowBackground(_ background: WindowBackground) -> some View {
    let translucent = background == .translucent
    return
      containerBackground(
        translucent ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.windowBackground), for: .window
      )
      .scrollContentBackground(translucent ? .hidden : .automatic)
      .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
  }
}
