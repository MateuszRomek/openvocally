import Foundation
import Testing
import os

@testable import Diagnostics

private func message(_ format: String, _ pieces: [LogPiece]) -> (text: String, withheld: Bool) {
  let line = LogRedactor.redact(
    format: format, pieces: pieces, date: .now, level: "notice", category: "paste")
  // Timestamp (23) + level (6) + category (12) + three spaces.
  return (String(line.text.dropFirst(44)), line.withheld)
}

private func piece(_ literal: String, _ placeholder: String, _ value: LogValue) -> LogPiece {
  LogPiece(literal: literal, placeholder: placeholder, value: value)
}

private func trailing(_ literal: String) -> LogPiece {
  LogPiece(literal: literal, placeholder: "", value: .other)
}

struct LogRedactorTests {
  @Test func `numbers and an escaped percent render`() {
    let result = message(
      "Cmd+V attempt %{public}ld failed after %{public}f s, 100%% sure",
      [
        piece("Cmd+V attempt ", "%{public}ld", .signed(2)),
        piece(" failed after ", "%{public}f", .double(1.5)),
        trailing(" s, 100%% sure"),
      ])
    #expect(result.text == "Cmd+V attempt 2 failed after 1.500000 s, 100% sure")
    #expect(!result.withheld)
  }

  @Test func `a message with no arguments renders as is`() {
    let text = "Sound output configuration changed"
    #expect(message(text, [trailing(text)]).text == text)
  }

  @Test func `strings need a public token and numbers do not`() {
    let result = message(
      "pub=%{public}s priv=%{private}s dflt=%s n=%ld d=%{public}f",
      [
        piece("pub=", "%{public}s", .string("deviceLost")),
        piece(" priv=", "%{private}s", .other),
        piece(" dflt=", "%s", .string("hello my secret transcript")),
        piece(" n=", "%ld", .signed(42)),
        piece(" d=", "%{public}f", .double(1.5)),
        trailing(""),
      ])
    #expect(result.text == "pub=deviceLost priv=<private> dflt=<private> n=42 d=1.500000")
  }

  @Test func `numeric conversions render`() {
    let result = message(
      "i=%{public}ld u=%{public}lu f=%{public}.*f ms=%{public}f b=%{bool,public}d x=%ld id=%{public}u",
      [
        piece("i=", "%{public}ld", .signed(42)),
        piece(" u=", "%{public}lu", .unsigned(255)),
        piece(" f=", "%{public}.*f", .double(1.234)),
        piece(" ms=", "%{public}f", .double(7.5)),
        piece(" b=", "%{bool,public}d", .signed(1)),
        piece(" x=", "%ld", .signed(-3)),
        piece(" id=", "%{public}u", .unsigned(9)),
        trailing(""),
      ])
    #expect(result.text == "i=42 u=255 f=1.234 ms=7.500000 b=true x=-3 id=9")
  }

  @Test func `precision and hex render`() {
    let result = message(
      "a=%{public}.2f h=%{public}x",
      [
        piece("a=", "%{public}.2f", .double(3.14159)), piece(" h=", "%{public}x", .unsigned(255)),
        trailing(""),
      ])
    #expect(result.text == "a=3.14 h=ff")
  }

  @Test(arguments: [
    [piece("a=", "%{public}s", .string("x")), trailing(" extra")],
    [piece("a=", "", .other), piece("", "%{public}s", .string("x")), trailing("")],
    [piece("a=", "%{public}s", .string("x"))],
  ])
  func `pieces that do not rebuild the format are withheld`(pieces: [LogPiece]) {
    let result = message("a=%{public}s", pieces)
    #expect(result.text == "<message withheld>")
    #expect(result.withheld)
  }

  @Test(arguments: ["%{private,mask.hash}s", "%{public,private}s", "%{public, sensitive}s"])
  func `a private token wins`(placeholder: String) {
    #expect(
      message("v=\(placeholder)", [piece("v=", placeholder, .string("x")), trailing("")]).text
        == "v=<private>")
  }

  @Test func `a value of the wrong kind is private`() {
    let result = message(
      "n=%{public}ld s=%{public}s",
      [piece("n=", "%{public}ld", .string("x")), piece(" s=", "%{public}s", .string(nil)), trailing("")])
    #expect(result.text == "n=<private> s=<private>")
  }

  @Test func `long lines are capped and newlines escaped`() {
    let long = String(repeating: "a", count: 5_000)
    let line = LogRedactor.redact(
      format: "%{public}s", pieces: [piece("", "%{public}s", .string(long)), trailing("")],
      date: .now, level: "error", category: "x")
    #expect(line.text.count == 2_000)
    #expect(line.text.hasSuffix("a…"))
    #expect(
      message("%{public}s", [piece("", "%{public}s", .string("one\ntwo")), trailing("")]).text == "one\\ntwo")
  }
}

struct DiagnosticsReportTests {
  @Test func `devices get numbered aliases`() {
    let lines = DiagnosticsReport.deviceLines([
      DiagnosticsDevice(direction: .input, transport: .bluetooth, isChosen: false, isSystemDefault: false),
      DiagnosticsDevice(direction: .input, transport: .bluetooth, isChosen: true, isSystemDefault: false),
      DiagnosticsDevice(direction: .output, transport: .builtIn, isChosen: false, isSystemDefault: true),
    ])
    #expect(
      lines == [
        "  Bluetooth input 1", "  Bluetooth input 2 (chosen)", "  Built-in output 1 (system default)",
      ])
    #expect(DiagnosticsReport.deviceLines([]) == ["  none found"])
  }

  @Test func `scrub hides the home folder and user names`() {
    let text = "/Users/anna/Library/x /Users/other/y by anna (Anna Example)"
    let scrubbed = DiagnosticsReport.scrub(
      text, home: "/Users/anna", userName: "anna", fullName: "Anna Example")
    #expect(scrubbed == "~/Library/x /Users/<user>/y by <user> (<user>)")
  }

  @Test func `scrub matches names in any case and only as whole words`() {
    let text = "ANNA ran com.openvocally.app on an Apple app"
    #expect(
      DiagnosticsReport.scrub(text, home: "/Users/x", userName: "app", fullName: "Anna")
        == "<user> ran com.openvocally.app on an Apple <user>")
  }

  @Test func `scrub covers escaped crash report paths and short user names`() {
    let report = #""procPath" : "\/Users\/jo\/Applications\/A.app", "path" : "\/Users\/old\/x""#
    #expect(
      DiagnosticsReport.scrub(report, home: "/Users/jo", userName: "jo", fullName: "")
        == #""procPath" : "~\/Applications\/A.app", "path" : "\/Users\/<user>\/x""#)
  }

  @Test func `crash reports lose machine identifiers and keep binary UUIDs`() {
    let report = """
      {"app_name":"OpenVocally","app_version":"1.0","incident_id":"8F2C-INCIDENT","name":"OpenVocally","share_with_app_devs":0,"slice_uuid":"bfbf46df-dfd1"}
      "incident" : "8F2C-INCIDENT",
      "crashReporterKey" : "A668-KEY",
      "deviceIdentifierForVendor":"C5B2-VENDOR",
      "sleepWakeUUID" : "6606-SLEEP",
      "slice_uuid":"bfbf46df-dfd1"
      """
    #expect(
      DiagnosticsReport.removingMachineIDs(report) == """
        {"app_name":"OpenVocally","app_version":"1.0","slice_uuid":"bfbf46df-dfd1"}
        "incident" : "<removed>",
        "crashReporterKey" : "<removed>",
        "deviceIdentifierForVendor":"<removed>",
        "sleepWakeUUID" : "<removed>",
        "slice_uuid":"bfbf46df-dfd1"
        """)
  }

  @Test func `log headers describe the scope`() {
    let launch = LogReadout(
      lines: ["a", "b"], total: 2, withheld: 1, includesEarlierLaunches: false,
      localFailure: "OSLogErrorDomain 9")
    #expect(
      launch.header
        == "Logs: this launch only (system log could not be opened: OSLogErrorDomain 9), 2 lines, 1 withheld")
    #expect(LogReadout(unavailable: "OSLogErrorDomain 3").header == "Logs: unavailable (OSLogErrorDomain 3)")
    let empty = LogReadout(
      lines: [], total: 0, withheld: 0, includesEarlierLaunches: false, localFailure: nil)
    #expect(empty.header == "Logs: this launch only, 0 lines")
    let capped = LogReadout(
      lines: Array(repeating: "x", count: 20_000), total: 21_500, withheld: 0, includesEarlierLaunches: true,
      localFailure: nil)
    #expect(
      capped.header == "Logs: system log, includes earlier launches, 20,000 lines, newest 20,000 of 21,500")
    #expect(capped.summary == "20,000 log lines from the last 3 days. Review it before you attach it.")
  }
}

struct LogArchiveTests {
  @Test func `the archive shows public values and hides the rest`() async throws {
    let secret = "secret-\(UUID().uuidString)"
    let token = "token-\(UUID().uuidString)"
    Logger(subsystem: "com.openvocally.app", category: "diagnostics-test")
      .notice("probe \(secret) \(secret, privacy: .private) \(token, privacy: .public)")
    var joined = ""
    for _ in 0..<20 {
      let readout = LogArchive.read(now: .now)
      joined = readout.lines.joined(separator: "\n")
      if joined.contains(token) { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    #expect(joined.contains("probe <private> <private> \(token)"))
    #expect(!joined.contains(secret))
  }

  @Test func `the archive renders numbers the way the app logs them`() async throws {
    let token = "token-\(UUID().uuidString)"
    let age = 12.345
    let fast = true
    Logger(subsystem: "com.openvocally.app", category: "diagnostics-test")
      .notice(
        "numbers \(token, privacy: .public) \(age, format: .fixed(precision: 1), privacy: .public) \(fast, privacy: .public) \(42)"
      )
    var line = ""
    for _ in 0..<20 {
      line = LogArchive.read(now: .now).lines.last { $0.contains(token) } ?? ""
      if !line.isEmpty { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    // The system log shows 12.3, but the store does not hand back a `.*` precision.
    #expect(line.hasSuffix("numbers \(token) 12.345 true 42"))
  }
}
