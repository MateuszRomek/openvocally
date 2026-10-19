#if DEBUG
  import AppKit
  import Darwin
  import DictationCore
  import Observation
  import QuartzCore
  import Storage
  import os

  private let logger = Logger(subsystem: "com.openvocally.app", category: "transcripts-harness")

  extension TranscriptsHarness {
    /// Runs `trigger` and waits up to 15 s for a mark that `matches`.
    static func expect(
      _ matches: @escaping (ScreenSignposts.Mark) -> Bool, _ trigger: () -> Void
    ) async -> ScreenSignposts.Mark? {
      waiterID += 1
      let id = waiterID
      return await withCheckedContinuation { continuation in
        waiter = Waiter(id: id, matches: matches, resume: continuation)
        trigger()
        Task {
          try? await Task.sleep(for: .seconds(15))
          guard let current = waiter, current.id == id else { return }
          waiter = nil
          current.resume.resume(returning: nil)
        }
      }
    }

    static func fail(_ step: String) -> Bool {
      logger.error("Harness step failed or timed out: \(step, privacy: .public)")
      results.append("failed\t0\t\(step)")
      return false
    }

    static func pause(_ duration: Duration) async {
      try? await Task.sleep(for: duration)
    }

    static func record(_ key: String, _ value: Double) {
      results.append("\(key)\t\(String(format: "%.2f", value))")
    }

    static func recordFrames(_ key: String, _ frames: [Double]) {
      for frame in frames { record("frames \(key)", frame) }
    }

    static func recordMemory(_ stage: String) {
      var usage = rusage_info_v4()
      let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
      }
      guard result == 0 else { return }
      record("memory MB \(stage)", Double(usage.ri_phys_footprint) / 1_048_576)
    }

    static func writeResults() {
      guard let outputURL else { return }
      do {
        try (results.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
      } catch {
        logger.error("Writing the results failed: \(String(describing: error), privacy: .public)")
      }
    }

    static func writeState(_ state: String) {
      guard let outputURL else { return }
      try? state.write(to: outputURL.appendingPathExtension("state"), atomically: true, encoding: .utf8)
    }
  }
#endif
