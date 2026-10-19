import Foundation

enum DiagnosticsReport {
  static let crashWindow: TimeInterval = 30 * 24 * 60 * 60

  static func text(_ snapshot: DiagnosticsSnapshot, logs: LogReadout, crash: String, now: Date) -> String {
    var lines = [
      "OpenVocally diagnostics, \(format(now, "yyyy-MM-dd HH:mm xx"))",
      "App: \(snapshot.version) (\(snapshot.build)), \(snapshot.bundleID)",
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "Mac: \(hardwareModel())",
      "",
      "Settings:",
    ]
    lines += snapshot.settings.map { "  \($0.name): \($0.value)" }
    lines += ["", "Audio devices:"]
    lines += deviceLines(snapshot.devices)
    lines += ["", logs.header]
    lines += logs.lines
    lines += ["", crash]
    return lines.joined(separator: "\n") + "\n"
  }

  static func deviceLines(_ devices: [DiagnosticsDevice]) -> [String] {
    guard !devices.isEmpty else { return ["  none found"] }
    var counts: [String: Int] = [:]
    return devices.map { device in
      let transport =
        switch device.transport {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .other: "Other"
        }
      let kind = "\(transport) \(device.direction == .input ? "input" : "output")"
      let number = counts[kind, default: 0] + 1
      counts[kind] = number
      let flags = [device.isChosen ? "chosen" : nil, device.isSystemDefault ? "system default" : nil]
        .compactMap(\.self)
      return "  \(kind) \(number)" + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
    }
  }

  static func scrub(_ text: String, home: String, userName: String, fullName: String) -> String {
    var text = text
    if !home.isEmpty {
      text = text.replacingOccurrences(of: home, with: "~")
      text = text.replacingOccurrences(of: home.replacingOccurrences(of: "/", with: "\\/"), with: "~")
    }
    // Crash reports are JSON with escaped slashes, "\/Users\/name".
    text = text.replacing(/(\\?\/)Users(\\?\/)[^\/\\\s"]+/) { "\($0.output.1)Users\($0.output.2)<user>" }
    for name in [fullName, userName] where name.count >= 3 {
      text = replacingWord(name, in: text)
    }
    return text
  }

  /// The header keys a report keeps. The header also carries `incident_id`, which repeats the
  /// body's `incident`.
  static let crashHeaderKeys = [
    "app_name", "app_version", "build_version", "bug_type", "os_version", "platform", "slice_uuid",
    "timestamp",
  ]

  /// Replaces `name` in any case where it stands alone, so a user named "app" keeps
  /// `com.openvocally.app` and "Apple" intact. scripts/diagnostics-export.sh checks the same rule.
  private static func replacingWord(_ name: String, in text: String) -> String {
    let pattern = "(?<![\\p{L}\\p{N}_.])\(NSRegularExpression.escapedPattern(for: name))(?![\\p{L}\\p{N}_])"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return text
    }
    return regex.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<user>")
  }

  /// Values that stay the same across crashes on one Mac, so a public report would tie separate
  /// issues to one machine. Binary image UUIDs stay: symbolication needs them.
  static func removingMachineIDs(_ report: String) -> String {
    let parts = report.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let header: String
    if let object = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
      let data = try? JSONSerialization.data(
        withJSONObject: object.filter { crashHeaderKeys.contains($0.key) }, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      header = text
    } else {
      header = "<crash report header withheld>"
    }
    let body = parts.count > 1 ? String(parts[1]) : ""
    let scrubbed = body.replacing(
      /("(?:crashReporterKey|deviceIdentifierForVendor|bootSessionUUID|sleepWakeUUID|incident|incident_id)"\s*:\s*)"[^"]*"/
    ) { "\($0.output.1)\"<removed>\"" }
    return header + "\n" + scrubbed
  }

  static func latestCrash(bundleID: String, now: Date) -> String {
    let none = "Latest crash report: none in the last 30 days"
    let directory = URL(filePath: realHome()).appending(path: "Library/Logs/DiagnosticReports")
    let manager = FileManager.default
    let files: [URL]
    do {
      files = try manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    } catch {
      let error = error as NSError
      if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return none }
      return "Latest crash report: could not be read (\(error.domain) \(error.code))"
    }
    let recent = files.compactMap { url -> (URL, Date)? in
      guard url.pathExtension == "ips",
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
        date >= now.addingTimeInterval(-crashWindow)
      else { return nil }
      return (url, date)
    }.sorted { $0.1 > $1.1 }
    for (url, date) in recent {
      guard let contents = try? String(contentsOf: url, encoding: .utf8),
        let firstLine = contents.split(separator: "\n", maxSplits: 1).first,
        let header = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
        header["bundleID"] as? String == bundleID
      else { continue }
      return "Latest crash report (\(format(date, "yyyy-MM-dd HH:mm"))):\n\(removingMachineIDs(contents))"
    }
    return none
  }

  private static func realHome() -> String {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
    return NSHomeDirectory()
  }

  private static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func format(_ date: Date, _ pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = pattern
    return formatter.string(from: date)
  }
}
