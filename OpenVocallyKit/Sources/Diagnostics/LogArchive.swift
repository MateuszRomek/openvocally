import Foundation
import OSLog

/// The only reader of the unified log. Each entry is redacted in the same expression that
/// reads it, so no raw argument value outlives the call to `LogRedactor.redact`.
enum LogArchive {
  static let subsystem = "com.openvocally.app"
  static let maxLines = 20_000
  static let window: TimeInterval = 3 * 24 * 60 * 60

  static func read(now: Date) -> LogReadout {
    let store: OSLogStore
    var localFailure: String?
    do {
      store = try OSLogStore.local()
    } catch {
      localFailure = describe(error)
      do {
        store = try OSLogStore(scope: .currentProcessIdentifier)
      } catch {
        return LogReadout(unavailable: describe(error))
      }
    }
    do {
      let position = store.position(date: now.addingTimeInterval(-window))
      let entries = try store.getEntries(
        at: position,
        matching: NSPredicate(
          format: "subsystem == %@ AND process == %@", subsystem, ProcessInfo.processInfo.processName))
      let ownPID = getpid()
      var lines: [RedactedLine] = []
      var scanned = 0
      var total = 0
      var earlierLaunches = false
      for case let entry as OSLogEntryLog in entries {
        scanned += 1
        if scanned % 1_000 == 0, Task.isCancelled { break }
        guard let level = levelName(entry.level) else { continue }
        total += 1
        if entry.processIdentifier != ownPID { earlierLaunches = true }
        let line = LogRedactor.redact(
          format: entry.formatString,
          pieces: entry.components.map(piece),
          date: entry.date, level: level, category: entry.category)
        lines.append(line)
        if lines.count >= maxLines * 2 { lines.removeFirst(lines.count - maxLines) }
      }
      if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
      return LogReadout(
        lines: lines.map(\.text), total: total, withheld: lines.count(where: \.withheld),
        includesEarlierLaunches: earlierLaunches, localFailure: localFailure)
    } catch {
      return LogReadout(unavailable: describe(error))
    }
  }

  private static func levelName(_ level: OSLogEntryLog.Level) -> String? {
    switch level {
    case .notice: "notice"
    case .error: "error"
    case .fault: "fault"
    default: nil
    }
  }

  private static func piece(_ component: OSLogMessageComponent) -> LogPiece {
    let value: LogValue =
      switch component.argumentCategory {
      case .string: .string(component.argumentStringValue)
      case .int64: .signed(component.argumentInt64Value)
      case .uInt64: .unsigned(component.argumentUInt64Value)
      case .double: .double(component.argumentDoubleValue)
      default: .other
      }
    return LogPiece(literal: component.formatSubstring, placeholder: component.placeholder, value: value)
  }

  private static func describe(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}
