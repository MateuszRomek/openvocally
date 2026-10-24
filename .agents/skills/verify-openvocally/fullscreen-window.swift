import AppKit

// `fullscreen-window <exit after s> <quit after s>` puts one empty window in full screen, which
// gives it a Space of its own, and leaves full screen after the first delay (0 stays) and quits
// after the second. `fullscreen-window --point` prints the centre of the main display in global
// screen points, the coordinates `-overlayProbe` reads.
let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--point" {
  let frame = NSScreen.main?.frame ?? .zero
  print(Int(frame.midX), Int(frame.midY))
  exit(0)
}
guard arguments.count == 2, let exitAfter = Double(arguments.first!), let quitAfter = Double(arguments.last!)
else {
  FileHandle.standardError.write(Data("Usage: fullscreen-window <exit after s> <quit after s> | --point\n".utf8))
  exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
  contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled, .resizable],
  backing: .buffered, defer: false)
window.collectionBehavior = [.fullScreenPrimary]
window.makeKeyAndOrderFront(nil)
app.activate()
window.toggleFullScreen(nil)
if exitAfter > 0 {
  DispatchQueue.main.asyncAfter(deadline: .now() + exitAfter) { window.toggleFullScreen(nil) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { exit(0) }
app.run()
