import AppKit

// Prints one line per connected display, main display first, in global points with the
// origin at the bottom left of the main display, the way AppKit and `NSEvent.mouseLocation`
// count them: `<display id> <x> <y> <width> <height> <visible x> <visible y> <visible width>
// <visible height> <notch 1 or 0>`. A built-in display has a notch only while the lid is open.
for screen in NSScreen.screens {
  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  let frame = screen.frame
  let visible = screen.visibleFrame
  let notch = screen.auxiliaryTopLeftArea != nil ? 1 : 0
  let fields: [Double] = [
    frame.minX, frame.minY, frame.width, frame.height, visible.minX, visible.minY, visible.width,
    visible.height,
  ]
  print(([String(id)] + fields.map { String(Int($0)) } + [String(notch)]).joined(separator: " "))
}
