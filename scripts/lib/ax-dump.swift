import ApplicationServices
import Foundation

// Prints the accessibility tree of the window titled argv[2] in the process with id argv[1], one
// element per line, as VoiceOver and Full Keyboard Access see it:
//   <depth> <role> label=<title or description> actions=<names> focusable=<yes|no>
// Labels can hold user content, so this is a Debug verification tool, run against seeded data.
// Exits 1 when the window is missing, 2 when this process may not read the accessibility tree.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, let pid = pid_t(arguments[0]) else {
  FileHandle.standardError.write(Data("usage: ax-dump <pid> <window title>\n".utf8))
  exit(64)
}
guard AXIsProcessTrusted() else { exit(2) }

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String {
  (attribute(element, name) as? String)?.replacingOccurrences(of: "\n", with: " ") ?? ""
}

func actions(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
  return (names as? [String]) ?? []
}

func focusable(_ element: AXUIElement) -> Bool {
  var settable = DarwinBoolean(false)
  return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success
    && settable.boolValue
}

func dump(_ element: AXUIElement, depth: Int) {
  let role = string(element, kAXRoleAttribute)
  let title = string(element, kAXTitleAttribute)
  let label = title.isEmpty ? string(element, kAXDescriptionAttribute) : title
  let names = actions(element).map { $0.components(separatedBy: "\n").first ?? $0 }
  print("\(depth) \(role) label=\(label) actions=\(names.joined(separator: ",")) focusable=\(focusable(element) ? "yes" : "no")")
  for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
    dump(child, depth: depth + 1)
  }
}

let app = AXUIElementCreateApplication(pid)
let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { string($0, kAXTitleAttribute) == arguments[1] }) else { exit(1) }
dump(window, depth: 0)
