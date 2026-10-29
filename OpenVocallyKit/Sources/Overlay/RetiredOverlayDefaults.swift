import Foundation

/// Settings from the island overlay, which the notch replaced. Removed at launch so an upgraded
/// install does not keep values nothing reads.
public enum RetiredOverlayDefaults {
  /// The overlay style (notch or island) and the island's screen edge.
  static let keys = ["overlayStyle", "overlayPlacement"]

  /// Idempotent, so it runs on every launch without tracking whether it already ran.
  public static func remove(from defaults: UserDefaults) {
    for key in keys {
      defaults.removeObject(forKey: key)
    }
  }
}
