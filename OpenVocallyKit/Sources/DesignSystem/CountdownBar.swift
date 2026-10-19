import SwiftUI

/// Time left before something closes, drawn as a thin line that shrinks toward its leading
/// edge until `deadline`. It takes the width it is offered. Under Reduce Motion it steps once
/// a second instead of draining smoothly.
public struct CountdownBar: View {
  let deadline: Date
  let total: Duration
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(until deadline: Date, total: Duration) {
    self.deadline = deadline
    self.total = total
  }

  public var body: some View {
    TimelineView(schedule) { context in
      let remaining = max(0, deadline.timeIntervalSince(context.date))
      Capsule()
        .fill(.token(.separator))
        .overlay(alignment: .leading) {
          Capsule()
            .fill(.secondary)
            .scaleEffect(x: fraction(remaining: remaining), anchor: .leading)
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("\(Int(remaining.rounded(.up))) seconds left")
    }
  }

  static let height: CGFloat = 2

  private var schedule: CountdownSchedule {
    CountdownSchedule(deadline: deadline, stepsBySecond: reduceMotion)
  }

  private func fraction(remaining: TimeInterval) -> CGFloat {
    let seconds = total / .seconds(1)
    guard seconds > 0 else { return 0 }
    let shown = reduceMotion ? remaining.rounded(.up) : remaining
    return CGFloat(min(1, shown / seconds))
  }
}

/// Redraws about 30 times a second, or on each whole second left under Reduce Motion, and
/// stops at the deadline so a finished bar costs nothing.
private struct CountdownSchedule: TimelineSchedule {
  let deadline: Date
  let stepsBySecond: Bool

  func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    var dates = [startDate]
    if stepsBySecond || mode == .lowFrequency {
      var left = deadline.timeIntervalSince(startDate).rounded(.down)
      while left >= 0 {
        dates.append(deadline.addingTimeInterval(-left))
        left -= 1
      }
    } else {
      var next = startDate.addingTimeInterval(Self.frame)
      while next < deadline {
        dates.append(next)
        next = next.addingTimeInterval(Self.frame)
      }
      dates.append(deadline)
    }
    return AnyIterator(dates.makeIterator())
  }

  private static let frame: TimeInterval = 1.0 / 30
}
