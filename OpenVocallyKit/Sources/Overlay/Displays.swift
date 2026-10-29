import AppKit

/// Which display a point is on, for the notch to follow the cursor and to log where the user
/// was looking.
@MainActor enum Displays {
  /// The display whose frame holds `point`. Edges follow `NSMouseInRect` for unflipped
  /// coordinates (min x and max y inside), so a point on a shared edge has one owner.
  static func display(
    containing point: CGPoint, in displays: [(id: CGDirectDisplayID, frame: CGRect)]
  ) -> CGDirectDisplayID? {
    displays.first { contains(point, $0.frame) }?.id
  }

  private static func contains(_ point: CGPoint, _ frame: CGRect) -> Bool {
    point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
  }

  /// The centre of the frontmost app's front window, in global screen points. Skips the
  /// transparent strip a full-screen window keeps above itself.
  static func focusedWindowCentre() -> CGPoint? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let primary = NSScreen.screens.first
    else { return nil }
    let front = windows.first {
      ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }
    guard let bounds = front?[kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: bounds)
    else { return nil }
    return CGPoint(x: rect.midX, y: primary.frame.maxY - rect.midY)
  }
}
