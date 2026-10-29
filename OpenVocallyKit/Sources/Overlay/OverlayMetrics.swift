import SwiftUI

/// Dictation notch geometry. Notch values are offsets from the hardware notch read from
/// `NSScreen`.
public enum OverlayMetrics {
  static let glyphSize: CGFloat = 14

  /// The fixed panel the notch animates inside, on every display.
  static let canvas = CGSize(width: 600, height: 180)

  /// Meter geometry. The bars keep a fixed frame, so a level change never resizes the notch.
  static let barCount = 16
  public static let barWidth: CGFloat = 2
  static let barSpacing: CGFloat = 2
  static let barMinHeight: CGFloat = 3
  static let barMaxHeight: CGFloat = 16

  /// How much smaller than the hardware notch the idle shape draws.
  static let notchIdleShrink = CGSize(width: 4, height: 2)
  /// Width added on each side of the notch at the compact level.
  static let notchWing: CGFloat = 64
  /// No top flare, so the hidden shape never reaches past the hardware notch.
  static let notchHiddenRadii = NotchRadii(top: 0, bottom: 12)
  static let notchCompactRadii = NotchRadii(top: 6, bottom: 12)
  static let notchAlertRadii = NotchRadii(top: 10, bottom: 20)
  /// Wing content sits this far from the camera edge and from the wing's outer end.
  static let notchWingInset: CGFloat = 10
  /// Side padding of the alert text below the notch.
  static let notchDropInset: CGFloat = 12
  /// The dictation notch's wing at the strip footprint: wide enough for the meter bars, so a
  /// content change within the strip never resizes the shape.
  static let notchStripWing =
    CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing + 2 * notchWingInset
  /// How far the dictation notch's notice reaches below the notch: one line and the countdown
  /// with their insets, fixed so one notice replacing another never resizes the shape.
  static let notchNoticeDrop: CGFloat = 48
  /// A 14 and 16 inch MacBook Pro notch, for previews on a Mac without one.
  /// The opacity of the one-pixel backing that keeps an idle notch panel unoccluded. Too faint to see.
  static let occlusionAnchorOpacity = 0.01
  public static let notchSimulated = CGSize(width: 185, height: 32)
}

/// The notch shape's corner radii: small where it meets the screen edge, larger below.
struct NotchRadii: Equatable, Sendable {
  let top: CGFloat
  let bottom: CGFloat
}
