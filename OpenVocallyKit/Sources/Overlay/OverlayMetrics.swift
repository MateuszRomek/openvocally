import DesignSystem
import SwiftUI

/// Overlay geometry from the overlay motion lab. Island values apply to the
/// floating capsule; notch values are offsets from the hardware notch read from `NSScreen`.
public enum OverlayMetrics {
  /// Island height at the compact level, which the bottom pill uses today.
  public static let islandHeight: CGFloat = 36
  /// The compact island never gets narrower than this, so short states share one base width.
  static let islandMinWidth: CGFloat = 120
  static let islandAlertRadius: CGFloat = 22
  static let islandCardRadius: CGFloat = 26
  static let glyphSize: CGFloat = 14
  public static let labelInset: CGFloat = 14
  /// A card's text wraps instead of growing wider. Alerts are one line and never reach it.
  public static let cardMaxWidth: CGFloat = 380
  /// Lines per card text, so the tallest card still fits the fixed canvas.
  static let cardLineLimit = 2
  public static let appearScale = Motion.appearScale

  /// The fixed panel the island animates inside, on every display.
  static let canvas = CGSize(width: 600, height: 180)
  /// The island's panel sits this far above the bottom of the work area.
  static let bottomInset: CGFloat = 24
  /// The top placement sits this far below the menu bar.
  static let topInset: CGFloat = 8

  /// Meter geometry. The bars keep a fixed frame, so a level change never resizes the island.
  static let barCount = 16
  public static let barWidth: CGFloat = 2
  static let barSpacing: CGFloat = 2
  public static let barMinHeight: CGFloat = 3
  static let barMaxHeight: CGFloat = 16

  /// How much smaller than the hardware notch the idle shape draws.
  static let notchIdleShrink = CGSize(width: 4, height: 2)
  /// Width added on each side of the notch at the compact level.
  static let notchWing: CGFloat = 64
  /// No top flare, so the hidden shape never reaches past the hardware notch.
  static let notchHiddenRadii = NotchRadii(top: 0, bottom: 12)
  static let notchCompactRadii = NotchRadii(top: 6, bottom: 12)
  static let notchAlertRadii = NotchRadii(top: 10, bottom: 20)
  static let notchCardRadii = NotchRadii(top: 14, bottom: 26)
  /// Wing content sits this far from the camera edge and from the wing's outer end.
  static let notchWingInset: CGFloat = 10
  /// Side and bottom padding of the alert and card text below the notch.
  static let notchDropInset: CGFloat = 12
  /// A 14 and 16 inch MacBook Pro notch, for previews on a Mac without one.
  public static let notchSimulated = CGSize(width: 185, height: 32)
}

/// The notch shape's corner radii: small where it meets the screen edge, larger below.
struct NotchRadii: Equatable, Sendable {
  let top: CGFloat
  let bottom: CGFloat
}
