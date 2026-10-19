#if DEBUG
  import AppKit
  import Darwin
  import DictationCore
  import Observation
  import QuartzCore
  import Storage
  import os

  /// Calls `step` on every display frame until it returns false, and returns the time between
  /// frames in milliseconds. A frame the main thread misses shows up as a longer gap.
  @MainActor final class FrameClock: NSObject {
    private let step: (Int) -> Bool
    private var continuation: CheckedContinuation<[Double], Never>?
    private var last: CFTimeInterval?
    private var frames: [Double] = []

    private init(step: @escaping (Int) -> Bool) {
      self.step = step
    }

    static func run(in window: NSWindow, step: @escaping (Int) -> Bool) async -> [Double] {
      guard let view = window.contentView else { return [] }
      let clock = FrameClock(step: step)
      return await withCheckedContinuation { continuation in
        clock.continuation = continuation
        view.displayLink(target: clock, selector: #selector(tick(_:))).add(to: .main, forMode: .common)
      }
    }

    @objc private func tick(_ link: CADisplayLink) {
      if let last { frames.append((link.timestamp - last) * 1000) }
      last = link.timestamp
      guard !step(frames.count) else { return }
      link.invalidate()
      continuation?.resume(returning: frames)
      continuation = nil
    }
  }
#endif
