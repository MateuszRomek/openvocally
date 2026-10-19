import Foundation

/// How Home writes report numbers.
public enum ReportFormat {
  /// Changes beyond this read as "+999%".
  static let deltaLimit = 999.0

  /// "+12.3%", "-4.0%", "0.0%", or "+999%" past the limit.
  public static func delta(_ percent: Double) -> String {
    if abs(percent) > deltaLimit {
      return "\(percent > 0 ? "+" : "-")\(Int(deltaLimit))%"
    }
    let digits = abs(percent).formatted(
      .number.precision(.fractionLength(1)).locale(.init(identifier: "en_US")))
    return "\(percent > 0 ? "+" : percent < 0 ? "-" : "")\(digits)%"
  }

  /// "45m" or "2h 5m", from minutes rounded to the nearest whole minute.
  public static func minutes(_ totalMinutes: Double) -> String {
    let whole = max(0, Int(totalMinutes.rounded()))
    let (hours, minutes) = whole.quotientAndRemainder(dividingBy: 60)
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
  }

  /// "24s" under a minute, at least "1s", else the minutes format.
  public static func session(_ duration: Duration) -> String {
    let seconds = duration / .seconds(1)
    if seconds < 60 { return "\(max(1, Int(seconds.rounded())))s" }
    return minutes(seconds / 60)
  }
}
