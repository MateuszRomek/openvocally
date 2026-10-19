import CoreGraphics
import Foundation

// Prints the window number of the largest on-screen window owned by the process id in
// argv[1], for `screencapture -l`, which captures that window alone even when other windows
// cover it. An optional argv[2] keeps only windows with that exact title. Exits 1 when there
// is no such window.
let arguments = Array(CommandLine.arguments.dropFirst())
let pid = Int(arguments.first ?? "") ?? -1
let title = arguments.count > 1 ? arguments[1] : nil
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

func width(_ window: [String: Any]) -> CGFloat {
  (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.width ?? 0
}

let ours = windows.filter {
  $0[kCGWindowOwnerPID as String] as? Int == pid
    && $0[kCGWindowLayer as String] as? Int == 0
    && (title == nil || $0[kCGWindowName as String] as? String == title)
}
guard let target = ours.max(by: { width($0) < width($1) }), let number = target[kCGWindowNumber as String] as? Int
else { exit(1) }
print(number)
