import ApplicationServices
import DictationCore
import Foundation
import Synchronization
import os

public enum HotkeysStartError: Error, Equatable {
  case accessibilityNotGranted
  case tapCreationFailed
}

public enum RebindError: Error, Equatable {
  case invalid(HotkeyBindings.Invalid)
  case persistFailed
  /// Hotkeys never started, so there is nothing to rebind.
  case unavailable
}

private let logger = Logger(subsystem: "com.openvocally.app", category: "hotkeys")

/// Owns one active keyboard event tap on a dedicated thread for the life of the process.
public final class Hotkeys: Sendable {
  public let events: AsyncStream<StampedCommand>
  private let matcher: Mutex<HotkeyMatcher>
  /// `CFMachPort` is not Sendable; the lock lets `ensureEnabled` reach it from any thread.
  /// Lock order: tapPort, then matcher.
  private let tapPort = Mutex<EventTapControl?>(nil)
  /// Held across a whole transactional rebind so two rebinds cannot interleave persist and swap.
  private let rebindLock = Mutex<Void>(())
  private let continuation: AsyncStream<StampedCommand>.Continuation

  init(bindings: HotkeyBindings) {
    (events, continuation) = AsyncStream<StampedCommand>.makeStream()
    matcher = Mutex(HotkeyMatcher(bindings: bindings))
  }

  public static func start(bindings: HotkeyBindings) async throws(HotkeysStartError) -> Hotkeys {
    guard AXIsProcessTrusted() else { throw .accessibilityNotGranted }
    let hotkeys = Hotkeys(bindings: bindings)
    let installed = await withCheckedContinuation { (started: CheckedContinuation<Bool, Never>) in
      let thread = Thread { runTap(hotkeys: hotkeys, started: started) }
      thread.name = "com.openvocally.hotkeys"
      thread.qualityOfService = .userInteractive
      thread.start()
    }
    guard installed else {
      logger.error("Keyboard event tap creation failed")
      throw .tapCreationFailed
    }
    return hotkeys
  }

  /// Arms or disarms the cancel trigger. Call on every phase the pipeline enters.
  public func phaseDidChange(to phase: DictationPhase) {
    matcher.withLock { $0.phaseDidChange(to: phase) }
  }

  public var bindings: HotkeyBindings {
    matcher.withLock { $0.bindings }
  }

  /// Swaps in bindings loaded from elsewhere, such as a store that opened after launch. A held
  /// push-to-talk is released with a stop.
  public func replaceBindings(_ bindings: HotkeyBindings) {
    rebindLock.withLock { _ in swap(to: bindings) }
  }

  /// Persists first, then swaps. The tap cannot fail to take a chord, so a persist
  /// failure is the only way to fail after validation, and it happens before anything changed.
  public func rebind(
    _ action: HotkeyAction, to trigger: HotkeyTrigger, persist: (HotkeyBindings) throws -> Void
  ) throws(RebindError) {
    try rebindLock.withLock { _ throws(RebindError) in
      let current = bindings
      let next: HotkeyBindings
      do throws(HotkeyBindings.Invalid) {
        next = try current.replacing(action, with: trigger)
      } catch {
        throw .invalid(error)
      }
      // A no-op swap would still release a held push-to-talk.
      guard next != current else { return }
      do {
        try persist(next)
      } catch {
        logger.error("Saving hotkey bindings failed: \(String(describing: error), privacy: .public)")
        throw .persistFailed
      }
      swap(to: next)
    }
  }

  /// Shortcut recording, where every fresh key-down passes so a shortcut recorder can capture any
  /// chord; Try it trial; or live. Leaving a mode aborts a one-key hold in progress.
  public func setMode(_ mode: ListenMode) {
    transition(at: .now()) { ((), $0.setMode(mode).map { [$0] } ?? []) }
  }

  /// Re-enables a tap the system disabled. A no-op while the tap is enabled, so a held
  /// push-to-talk survives.
  public func ensureEnabled(reason: String = "check") {
    guard resetAndEnable(onlyIfDisabled: true) != nil else { return }
    logger.notice("Event tap was disabled; re-enabled on \(reason, privacy: .public)")
  }

  /// The tap's answer to the system disabling it, by timeout or user input: releases
  /// any hold and re-enables, whatever the tap reports.
  func tapWasDisabled(_ type: CGEventType) {
    let enabled = resetAndEnable(onlyIfDisabled: false) ?? false
    logger.notice(
      "Event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public), re-enabled: \(enabled, privacy: .public)"
    )
  }

  /// Removes the tap and ends `events`. Safe to call more than once.
  public func stop() {
    tapPort.withLock { tap in
      tap?.disable()
      tap = nil
    }
    continuation.finish()
  }

  /// Releases the hold before enabling, under the tap lock, so a press the re-enabled tap
  /// delivers is never stopped by this reset. Returns whether the tap is enabled after, or nil
  /// when nothing was done.
  private func resetAndEnable(onlyIfDisabled: Bool) -> Bool? {
    tapPort.withLock { tap -> Bool? in
      guard let tap, !(onlyIfDisabled && tap.isEnabled()) else { return nil }
      transition(at: .now()) { ((), $0.tapWasReset().map { [$0] } ?? []) }
      tap.enable()
      return tap.isEnabled()
    }
  }

  /// Creates the control inside the lock, because `EventTapControl` is not Sendable.
  func attachTap(_ make: () -> sending EventTapControl?) {
    tapPort.withLock { $0 = make() }
  }

  /// Runs one key event through the matcher, as the tap does.
  func handle(_ event: KeyEvent, at stamp: HostTime = .now()) -> Verdict {
    transition(at: stamp) { matcher in
      let verdict = matcher.handle(event, at: stamp)
      return (verdict, verdict.emits)
    }
  }

  /// Creates the port inside the lock so it starts in the lock's region; a port created
  /// outside could not be moved in, because `CFMachPort` is not Sendable. The context pointer
  /// arrives as an address for the same reason: a captured pointer would tie the port to the caller.
  func installTap(context: UInt) -> Bool {
    tapPort.withLock { stored in
      let mask =
        CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, userInfo in handleTapEvent(type: type, event: event, userInfo: userInfo)
        },
        userInfo: UnsafeMutableRawPointer(bitPattern: context)
      )
      guard let port = created else { return false }
      let source = CFMachPortCreateRunLoopSource(nil, port, 0)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CGEvent.tapEnable(tap: port, enable: true)
      stored = EventTapControl(port: port)
      return true
    }
  }

  /// Callers hold `rebindLock`.
  private func swap(to bindings: HotkeyBindings) {
    transition(at: .now()) { ((), $0.rebind(bindings).map { [$0] } ?? []) }
  }

  /// Yields inside the lock so stream order matches transition order across the tap
  /// thread and callers. `yield` on an unbounded stream does not block.
  private func transition<Result>(
    at stamp: HostTime, _ body: (inout HotkeyMatcher) -> (Result, [DictationCommand])
  ) -> Result {
    matcher.withLock { matcher in
      let (result, emitted) = body(&matcher)
      for command in emitted { continuation.yield(StampedCommand(command: command, at: stamp)) }
      return result
    }
  }
}
