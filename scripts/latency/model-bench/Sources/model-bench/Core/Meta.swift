import Darwin
import Foundation

/// `meta.json`: where and how a result folder was produced.
struct Meta: Codable {
  struct Git: Codable {
    var commit: String
    var dirty: Bool
  }

  struct ModelNote: Codable {
    var model: String
    var status: String
    var location: String?
    var detail: String?
  }

  var chip: String
  var memoryGB: Int
  var macOS: String
  var git: Git?
  var startedAt: Date
  var finishedAt: Date?
  var loadAverageAtStart: [Double]
  var thermalAtStart: String
  var thermalAtEnd: String?
  var arguments: [String]
  var models: [ModelNote] = []
  var note = tierNote

  enum CodingKeys: String, CodingKey {
    case chip, macOS, git, arguments, models, note
    case memoryGB = "memory_gb"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case loadAverageAtStart = "load_average_at_start"
    case thermalAtStart = "thermal_at_start"
    case thermalAtEnd = "thermal_at_end"
  }

  static func current(arguments: [String]) -> Meta {
    var loads = [Double](repeating: 0, count: 3)
    let count = getloadavg(&loads, 3)
    return Meta(
      chip: sysctlString("machdep.cpu.brand_string"),
      memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
      macOS: "\(ProcessInfo.processInfo.operatingSystemVersionString)",
      git: gitState(), startedAt: .now, loadAverageAtStart: Array(loads.prefix(Int(max(count, 0)))),
      thermalAtStart: thermalState(), arguments: arguments)
  }

  func write(to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: file)
  }
}

private func sysctlString(_ name: String) -> String {
  var size = 0
  sysctlbyname(name, nil, &size, nil, 0)
  var bytes = [CChar](repeating: 0, count: size)
  sysctlbyname(name, &bytes, &size, nil, 0)
  return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func gitState() -> Meta.Git? {
  guard let commit = git(["rev-parse", "HEAD"]), let status = git(["status", "--porcelain"]) else {
    return nil
  }
  return Meta.Git(commit: commit, dirty: !status.isEmpty)
}

private func git(_ arguments: [String]) -> String? {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/git")
  process.arguments = ["-C", repositoryRoot.path] + arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
  } catch {
    return nil
  }
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { return nil }
  return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
