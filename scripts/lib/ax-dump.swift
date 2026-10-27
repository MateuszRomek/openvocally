import ApplicationServices
import Foundation

// Reads a window's accessibility tree the way VoiceOver does, as a separate client. argv: the
// process id, the window title, a heading that must be in the tree (empty for none) and the
// output file. Writes one "role | label | value" line per element that says something, and per
// control, indented by depth. Exits 1 without the Accessibility permission or when the window is
// missing, and 2 when the heading is not found. SwiftUI builds a Form's rows only for a client like this, so an
// in-process walk of NSAccessibility sees the window alone.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let pid = pid_t(arguments[0]) else {
  FileHandle.standardError.write(Data("usage: ax-dump <pid> <window title> <heading> <output file>\n".utf8))
  exit(64)
}
let (title, heading, output) = (arguments[1], arguments[2], arguments[3])
guard AXIsProcessTrusted() else {
  FileHandle.standardError.write(Data("ax-dump: this terminal needs the Accessibility permission\n".utf8))
  exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func string(_ element: AXUIElement, _ name: String) -> String {
  switch attribute(element, name) {
  case let text as String: text
  case let text as NSAttributedString: text.string
  case let number as NSNumber: number.stringValue
  default: ""
  }
}

func find(_ element: AXUIElement, text: String, depth: Int) -> AXUIElement? {
  guard depth < 60 else { return nil }
  let role = string(element, kAXRoleAttribute)
  if role == kAXStaticTextRole || role == "AXHeading",
    [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { string(element, $0) == text })
  {
    return element
  }
  for child in children(element) {
    if let found = find(child, text: text, depth: depth + 1) { return found }
  }
  return nil
}

let controlRoles: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXTextFieldRole, kAXPopUpButtonRole, "AXLink"]

func describe(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
  guard depth < 60 else { return }
  let role = string(element, kAXRoleAttribute)
  let label = [kAXTitleAttribute, kAXDescriptionAttribute].map { string(element, $0) }
    .filter { !$0.isEmpty }.joined(separator: " ")
  let value = string(element, kAXValueAttribute)
  if !label.isEmpty || !value.isEmpty || controlRoles.contains(role) {
    lines.append(String(repeating: "  ", count: depth) + "\(role) | \(label) | \(value)")
  }
  for child in children(element) { describe(child, depth: depth + 1, into: &lines) }
}

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { string($0, kAXTitleAttribute) == title }) else {
  FileHandle.standardError.write(Data("ax-dump: no window titled \(title)\n".utf8))
  exit(1)
}
var status: Int32 = 0
if !heading.isEmpty {
  if find(window, text: heading, depth: 0) == nil {
    FileHandle.standardError.write(Data("ax-dump: no heading \(heading)\n".utf8))
    status = 2
  }
}
var lines: [String] = []
describe(window, depth: 0, into: &lines)
do {
  try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
} catch {
  FileHandle.standardError.write(Data("ax-dump: \(error)\n".utf8))
  exit(1)
}
exit(status)
