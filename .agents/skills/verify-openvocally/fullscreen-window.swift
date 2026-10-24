import AppKit

// `fullscreen-window <exit after s> <quit after s> <events file>` puts one empty window in full
// screen, which gives it a Space of its own, and leaves full screen after the first delay (0
// stays) and quits after the second. It appends `entered`, `exited` and `active` to the events
// file, so a script can wait for the Space change instead of guessing its length.
// `fullscreen-window --point` prints the centre of the main display in global screen points,
// the coordinates `-overlayProbe` reads.
let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--point" {
  let frame = NSScreen.main?.frame ?? .zero
  print(Int(frame.midX), Int(frame.midY))
  exit(0)
}
let values = Array(arguments)
guard values.count == 3, let exitAfter = Double(values[0]), let quitAfter = Double(values[1]) else {
  FileHandle.standardError.write(
    Data("Usage: fullscreen-window <exit after s> <quit after s> <events file> | --point\n".utf8))
  exit(2)
}
let events = values[2]
FileManager.default.createFile(atPath: events, contents: nil)

func record(_ event: String) {
  guard let handle = FileHandle(forWritingAtPath: events) else { return }
  handle.seekToEndOfFile()
  handle.write(Data((event + "\n").utf8))
  try? handle.close()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
  contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled, .resizable],
  backing: .buffered, defer: false)
window.collectionBehavior = [.fullScreenPrimary]
let center = NotificationCenter.default
center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
  record("entered")
}
center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
  record("exited")
}
center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
  record("active")
}
window.makeKeyAndOrderFront(nil)
app.activate()
window.toggleFullScreen(nil)
if exitAfter > 0 {
  DispatchQueue.main.asyncAfter(deadline: .now() + exitAfter) { window.toggleFullScreen(nil) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { exit(0) }
app.run()
