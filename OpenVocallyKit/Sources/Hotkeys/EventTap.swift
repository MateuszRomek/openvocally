import ApplicationServices
import DictationCore
import os

private let logger = Logger(subsystem: "com.openvocally.app", category: "hotkeys")

/// The two tap operations re-enabling needs, so tests can stand in for the system tap.
struct EventTapControl {
  let isEnabled: () -> Bool
  let enable: () -> Void
  let disable: () -> Void

  init(isEnabled: @escaping () -> Bool, enable: @escaping () -> Void, disable: @escaping () -> Void = {}) {
    self.isEnabled = isEnabled
    self.enable = enable
    self.disable = disable
  }

  init(port: CFMachPort) {
    isEnabled = { CGEvent.tapIsEnabled(tap: port) }
    enable = { CGEvent.tapEnable(tap: port, enable: true) }
    disable = {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
  }
}

/// Confined to the tap thread: created there and read only by the callback, which runs
/// there. It reaches the callback through `userInfo`, so it needs no Sendable conformance.
final class TapContext {
  let hotkeys: Hotkeys
  var loggedBadTimestamp = false

  init(hotkeys: Hotkeys) {
    self.hotkeys = hotkeys
  }
}

func runTap(hotkeys: Hotkeys, started: CheckedContinuation<Bool, Never>) {
  // Retained for the life of the run loop. `stop()` invalidates the port, which removes the
  // tap's only source, so the run loop returns and no callback can run after the release.
  let context = Unmanaged.passRetained(TapContext(hotkeys: hotkeys))
  guard hotkeys.installTap(context: UInt(bitPattern: context.toOpaque())) else {
    context.release()
    started.resume(returning: false)
    return
  }
  started.resume(returning: true)
  CFRunLoopRun()
  context.release()
}

func handleTapEvent(
  type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  let pass = Unmanaged.passUnretained(event)
  guard let userInfo else { return pass }
  let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
  let hotkeys = context.hotkeys
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    hotkeys.tapWasDisabled(type)
    return pass
  case .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown:
    let keyEvent = KeyEvent(event, type)
    let now = HostTime.now()
    let stamp = trustedStamp(event.timestamp, now: now)
    if stamp == now, !context.loggedBadTimestamp {
      context.loggedBadTimestamp = true
      let age = now.milliseconds(since: HostTime(nanoseconds: event.timestamp))
      logger.notice(
        "Key event timestamp \(age, format: .fixed(precision: 1), privacy: .public) ms old; using now")
    }
    let verdict = hotkeys.handle(keyEvent, at: stamp)
    return verdict.disposition == .consume ? nil : pass
  default:
    return pass
  }
}

/// The press instant trims the recording and starts LB-01, so a zero, stale or future
/// timestamp from a remapper or a synthetic event falls back to now.
func trustedStamp(_ timestamp: CGEventTimestamp, now: HostTime) -> HostTime {
  let stamp = HostTime(nanoseconds: timestamp)
  let age = now.milliseconds(since: stamp)
  return age < 0 || age > 1000 ? now : stamp
}

extension KeyEvent {
  /// The tap's side of the shared parser in `KeyEvent.init(_:keyCode:rawFlags:isAutorepeat:)`.
  init(_ event: CGEvent, _ type: CGEventType) {
    let kind: Kind =
      switch type {
      case .flagsChanged: .flagsChanged
      case .leftMouseDown, .rightMouseDown, .otherMouseDown: .pointerDown
      case .keyUp: .keyUp
      default: .keyDown
      }
    self.init(
      kind,
      keyCode: KeyCode(
        rawValue: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))),
      rawFlags: event.flags.rawValue,
      isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
  }
}
