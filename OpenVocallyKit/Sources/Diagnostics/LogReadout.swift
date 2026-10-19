import Foundation

/// Redacted log lines, oldest first, with what the header needs to describe them.
struct LogReadout: Sendable, Equatable {
  let lines: [String]
  let total: Int
  let withheld: Int
  let includesEarlierLaunches: Bool
  let localFailure: String?
  let unavailable: String?

  init(lines: [String], total: Int, withheld: Int, includesEarlierLaunches: Bool, localFailure: String?) {
    self.lines = lines
    self.total = total
    self.withheld = withheld
    self.includesEarlierLaunches = includesEarlierLaunches
    self.localFailure = localFailure
    unavailable = nil
  }

  init(unavailable: String) {
    lines = []
    total = 0
    withheld = 0
    includesEarlierLaunches = false
    localFailure = nil
    self.unavailable = unavailable
  }

  var header: String {
    if let unavailable { return "Logs: unavailable (\(unavailable))" }
    var scope = includesEarlierLaunches ? "system log, includes earlier launches" : "this launch only"
    if let localFailure { scope += " (system log could not be opened: \(localFailure))" }
    var header = "Logs: \(scope), \(grouped(lines.count)) lines"
    if withheld > 0 { header += ", \(grouped(withheld)) withheld" }
    if total > lines.count { header += ", newest \(grouped(lines.count)) of \(grouped(total))" }
    return header
  }

  var summary: String {
    if unavailable != nil { return "The logs could not be read. Review the file before you attach it." }
    let noun = lines.count == 1 ? "log line" : "log lines"
    return "\(grouped(lines.count)) \(noun) from the last 3 days. Review it before you attach it."
  }
}

func grouped(_ number: Int) -> String {
  number.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
}
