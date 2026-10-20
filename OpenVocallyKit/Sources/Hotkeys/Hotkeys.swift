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

/// Where the tap stands. An active tap sends every key and click it passes as this process, so
/// once the process may no longer post events, WindowServer drops them all and the whole Mac
/// stops taking input. The tap is suspended then, and installed again once the grant is back.
enum TapSlot {
  case installing
  case installed(EventTapControl)
  case suspended
  case stopped
}

/// Owns one active keyboard event tap on a dedicated thread for the life of the process, except
/// while the process lacks the grants an active tap needs.
public final class Hotkeys: Sendable {
  public let events: AsyncStream<StampedCommand>
  private let matcher: Mutex<HotkeyMatcher>
  /// `CFMachPort` is not Sendable; the lock lets `ensureEnabled` reach it from any thread.
  /// Lock order: tapPort, then matcher.
  private let tapPort = Mutex<TapSlot>(.installing)
  /// Whether the process may run an active tap now.
  private let isTrusted: @Sendable () -> Bool
  /// Starts a tap thread that calls `installTap`, and returns whether it installed.
  private let install: @Sendable (Hotkeys) async -> Bool
  /// Held across a whole transactional rebind so two rebinds cannot interleave persist and swap.
  private let rebindLock = Mutex<Void>(())
  private let continuation: AsyncStream<StampedCommand>.Continuation

  init(
    bindings: HotkeyBindings, isTrusted: @escaping @Sendable () -> Bool = Hotkeys.systemTrust,
    install: @escaping @Sendable (Hotkeys) async -> Bool = Hotkeys.spawnTap
  ) {
    (events, continuation) = AsyncStream<StampedCommand>.makeStream()
    matcher = Mutex(HotkeyMatcher(bindings: bindings))
    self.isTrusted = isTrusted
    self.install = install
  }

  /// Accessibility lets the tap filter events. WindowServer checks the right to post events
  /// separately, on its own schedule, for every event the tap passes, and a rebuilt or re-signed
  /// app can lose that right while it runs.
  static func systemTrust() -> Bool {
    AXIsProcessTrusted() && CGPreflightPostEventAccess()
  }

  static func spawnTap(_ hotkeys: Hotkeys) async -> Bool {
    await withCheckedContinuation { (started: CheckedContinuation<Bool, Never>) in
      let thread = Thread { runTap(hotkeys: hotkeys, started: started) }
      thread.name = "com.openvocally.hotkeys"
      thread.qualityOfService = .userInteractive
      thread.start()
    }
  }

  public static func start(bindings: HotkeyBindings) async throws(HotkeysStartError) -> Hotkeys {
    let hotkeys = Hotkeys(bindings: bindings)
    guard hotkeys.isTrusted() else { throw .accessibilityNotGranted }
    guard await hotkeys.install(hotkeys) else {
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

  /// Suspends the tap when the grants are gone, installs it again when they are back, and
  /// re-enables a tap the system disabled. A no-op on an enabled, trusted tap, so a held
  /// push-to-talk survives. Returns whether the tap is installed after.
  @discardableResult public func ensureEnabled(reason: String = "check") async -> Bool {
    let trusted = isTrusted()
    let reinstall = tapPort.withLock { slot -> Bool in
      switch slot {
      case .installing, .stopped:
        return false
      case .suspended:
        guard trusted else { return false }
        slot = .installing
        return true
      case .installed(let tap):
        if !trusted {
          suspend(&slot, tap)
          logger.error("Event tap suspended on \(reason, privacy: .public): no right to post events")
        } else if !tap.isEnabled() {
          reset()
          tap.enable()
          logger.notice("Event tap was disabled; re-enabled on \(reason, privacy: .public)")
        }
        return false
      }
    }
    if reinstall {
      let installed = await install(self)
      if !installed { tapPort.withLock { if case .installing = $0 { $0 = .suspended } } }
      logger.notice("Event tap reinstalled on \(reason, privacy: .public): \(installed, privacy: .public)")
    }
    return tapPort.withLock { if case .installed = $0 { true } else { false } }
  }

  /// The tap's answer to the system disabling it, by timeout or user input: releases any hold,
  /// then re-enables, whatever the tap reports. Without the grants it suspends instead, since
  /// WindowServer would drop every event the tap passed.
  func tapWasDisabled(_ type: CGEventType) {
    let trusted = isTrusted()
    let enabled = tapPort.withLock { slot -> Bool in
      guard case .installed(let tap) = slot else { return false }
      guard trusted else {
        suspend(&slot, tap)
        return false
      }
      reset()
      tap.enable()
      return tap.isEnabled()
    }
    let cause = type == .tapDisabledByTimeout ? "timeout" : "user input"
    if trusted {
      logger.notice(
        "Event tap disabled by \(cause, privacy: .public), re-enabled: \(enabled, privacy: .public)")
    } else {
      logger.error("Event tap disabled by \(cause, privacy: .public); suspended: no right to post events")
    }
  }

  /// Removes the tap and ends `events`. Safe to call more than once.
  public func stop() {
    tapPort.withLock { slot in
      if case .installed(let tap) = slot { tap.disable() }
      slot = .stopped
    }
    continuation.finish()
  }

  /// Removes the tap, which ends its thread, and releases any hold. Callers hold `tapPort`.
  private func suspend(_ slot: inout TapSlot, _ tap: EventTapControl) {
    tap.disable()
    slot = .suspended
    reset()
  }

  /// Releases any hold. Before enabling, and under the tap lock, so a press the re-enabled tap
  /// delivers is never stopped by this reset.
  private func reset() {
    transition(at: .now()) { ((), $0.tapWasReset().map { [$0] } ?? []) }
  }

  /// Creates the control inside the lock, because `EventTapControl` is not Sendable. Installs
  /// only while an install is due, so a tap created after `stop()` is removed at once.
  @discardableResult func attachTap(_ make: () -> sending EventTapControl?) -> Bool {
    tapPort.withLock { slot in
      guard case .installing = slot, let tap = make() else { return false }
      slot = .installed(tap)
      return true
    }
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
    tapPort.withLock { slot in
      guard case .installing = slot else { return false }
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
      slot = .installed(EventTapControl(port: port))
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
