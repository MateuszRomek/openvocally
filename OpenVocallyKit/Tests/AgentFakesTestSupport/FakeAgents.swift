import AgentFakes
import Foundation
import Synchronization

/// The fakes installed once per test process at `<tmp>/agent-fakes-<pid>/<scenario>/<provider>`.
package struct FakeAgents: Sendable {
  package let root: URL

  package static func shared() throws -> FakeAgents { try installed.get() }

  private static let installed = Result { () throws -> FakeAgents in
    // A write to a fake that already exited must fail the test, not kill the runner.
    signal(SIGPIPE, SIG_IGN)
    let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    let built = products.appending(path: "FakeAgentCLI")
    let root = processRoot
    atexit { try? FileManager.default.removeItem(at: FakeAgents.processRoot) }
    let result = try ProcessRun.run(built, ["install", root.path(percentEncoded: false)])
    guard result.exitCode == 0 else { throw FakeAgentsError.installFailed(result.stderr) }
    return FakeAgents(root: root)
  }

  /// Per process, so parallel test runs never replace each other's binaries; removed at exit.
  private static var processRoot: URL {
    FileManager.default.temporaryDirectory.appending(path: "agent-fakes-\(getpid())")
  }

  /// The binary path a host's provider setting points at.
  package func path(_ provider: Provider, _ scenario: ScenarioID) -> URL {
    Installer.path(root: root, provider, scenario)
  }
}

package enum FakeAgentsError: Error {
  case installFailed(String)
}

private final class BundleMarker {}

/// A finished child process. Both pipes are drained before waiting, so a full pipe cannot hang it.
package struct ProcessRun: Sendable {
  package let stdout: String
  package let stderr: String
  package let exitCode: Int32

  package static func run(_ executable: URL, _ arguments: [String]) throws -> ProcessRun {
    let process = Process()
    let out = Pipe()
    let err = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let errData = Mutex(Data())
    let drained = DispatchSemaphore(value: 0)
    Thread {
      errData.withLock { $0 = err.fileHandleForReading.readDataToEndOfFile() }
      drained.signal()
    }.start()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    return ProcessRun(
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData.withLock { $0 }, as: UTF8.self),
      exitCode: process.terminationStatus)
  }
}
