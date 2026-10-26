import AppKit
import SwiftUI

enum Clipboard {
  /// A plain, persistent write: the user asked for this text, so clipboard managers may keep it,
  /// unlike the transient write the paste path makes and restores. `announcement` tells
  /// VoiceOver what was copied without reading the text back.
  static func write(_ text: String, announcement: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
    AccessibilityNotification.Announcement(announcement).post()
  }
}
