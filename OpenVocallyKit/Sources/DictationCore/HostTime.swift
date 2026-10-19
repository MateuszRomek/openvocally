import Darwin

private let nanosecondsPerTick: Double = {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  return Double(timebase.numer) / Double(timebase.denom)
}()

/// Mach host ticks, the clock of AVAudioTime.hostTime. A CGEvent timestamp counts the same
/// clock in nanoseconds; use `init(nanoseconds:)` for it.
public struct HostTime: Comparable, Hashable, Sendable {
  let ticks: UInt64

  public init(ticks: UInt64) {
    self.ticks = ticks
  }

  /// The same clock counted in nanoseconds, as CGEventGetTimestamp reports it.
  public init(nanoseconds: UInt64) {
    ticks = UInt64((Double(nanoseconds) / nanosecondsPerTick).rounded())
  }

  public static func now() -> HostTime {
    HostTime(ticks: mach_absolute_time())
  }

  public static func < (lhs: HostTime, rhs: HostTime) -> Bool {
    lhs.ticks < rhs.ticks
  }

  public func milliseconds(since other: HostTime) -> Double {
    nanoseconds(since: other) / 1_000_000
  }

  public func duration(since other: HostTime) -> Duration {
    .nanoseconds(Int64(nanoseconds(since: other).rounded()))
  }

  public func advanced(by duration: Duration) -> HostTime {
    let (seconds, attoseconds) = duration.components
    let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
    return advanced(byNanoseconds: nanoseconds)
  }

  package func seconds(since other: HostTime) -> Double {
    nanoseconds(since: other) / 1e9
  }

  package func advanced(bySeconds seconds: Double) -> HostTime {
    advanced(byNanoseconds: seconds * 1e9)
  }

  private func advanced(byNanoseconds nanoseconds: Double) -> HostTime {
    let delta = Int64((nanoseconds / nanosecondsPerTick).rounded())
    return HostTime(ticks: UInt64(clamping: Int64(clamping: ticks) &+ delta))
  }

  private func nanoseconds(since other: HostTime) -> Double {
    let delta = ticks >= other.ticks ? Double(ticks - other.ticks) : -Double(other.ticks - ticks)
    return delta * nanosecondsPerTick
  }
}
