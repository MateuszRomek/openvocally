import Darwin
import Foundation

/// An exclusive `flock` held for the whole timed section, so two bench processes never time on a
/// machine the other is loading. Released when the value is dropped or the process exits.
final class BenchLock {
  static let defaultPath = "/tmp/openvocally-model-bench.lock"

  private let descriptor: Int32

  init(path: String = BenchLock.defaultPath) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    descriptor = open(path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else { throw BenchError("cannot open lock file \(path): errno \(errno)") }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
    guard errno == EWOULDBLOCK else { throw BenchError("flock failed: errno \(errno)") }
    log("waiting for bench lock \(path) (another bench is timing)")
    let clock = ContinuousClock()
    let start = clock.now
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw BenchError("flock failed: errno \(errno)") }
    }
    log("got bench lock after \(Int((clock.now - start) / .seconds(1))) s")
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}

func log(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
