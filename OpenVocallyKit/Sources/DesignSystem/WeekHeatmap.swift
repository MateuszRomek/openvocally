import SwiftUI

/// A value for each hour of the week, as a grid of seven day rows and 24 hour columns under a
/// title. Busier hours fill with more `accent` ink; empty hours keep a faint cell so the
/// grid's shape stays. The title's second line names the busiest hour, or the hovered one.
///
/// The cells draw in one canvas with one hover handler, so moving the pointer redraws a single
/// view instead of 168.
public struct WeekHeatmap: View {
  let title: String
  /// Seven rows, Monday first, of 24 values from midnight.
  let values: [[Int]]
  let noun: String
  let emptyText: String
  private let peak: Int
  private let busiest: Slot

  @State private var hovered: Slot?
  @State private var gridWidth: CGFloat = 0
  @Environment(\.calendar) private var calendar

  private struct Slot: Equatable {
    let day: Int
    let hour: Int
  }

  public init(_ title: String, values: [[Int]], noun: String, emptyText: String) {
    self.title = title
    self.values = values
    self.noun = noun
    self.emptyText = emptyText
    var busiest = Slot(day: 0, hour: 0)
    var peak = 0
    for (day, row) in values.prefix(7).enumerated() {
      for (hour, value) in row.prefix(24).enumerated() where value > peak {
        peak = value
        busiest = Slot(day: day, hour: hour)
      }
    }
    self.peak = peak
    self.busiest = busiest
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Space.m.points) {
      SectionHeader(title: title, detail: peak > 0 ? readout : nil)
      ZStack {
        grid.opacity(peak > 0 ? 1 : Self.emptyFade)
        if peak == 0 {
          Text(emptyText).textStyle(.callout).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var grid: some View {
    HStack(alignment: .top, spacing: Space.s.points) {
      VStack(alignment: .leading, spacing: Self.gap) {
        ForEach(0..<7, id: \.self) { day in
          Text(dayName(day))
            .textStyle(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: rowHeight)
        }
      }
      .fixedSize()
      VStack(alignment: .leading, spacing: Space.xs.points) {
        cells
        ZStack(alignment: .leading) {
          ForEach([0, 6, 12, 18], id: \.self) { hour in
            Text(hourText(hour))
              .textStyle(.caption)
              .foregroundStyle(.secondary)
              .fixedSize()
              .offset(x: CGFloat(hour) * (cellWidth(gridWidth) + Self.gap))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var cells: some View {
    Canvas { context, size in
      let width = cellWidth(size.width)
      let height = cellHeight(width)
      for day in 0..<7 {
        for hour in 0..<24 {
          let rect = CGRect(
            x: CGFloat(hour) * (width + Self.gap), y: CGFloat(day) * (height + Self.gap),
            width: width, height: height)
          let shape = Path(roundedRect: rect, cornerRadius: Self.cellRadius, style: .continuous)
          context.fill(shape, with: .color(fill(value(day, hour))))
          if hovered == Slot(day: day, hour: hour) {
            context.stroke(shape, with: .color(.primary.opacity(Self.hoverRing)), lineWidth: 1)
          }
        }
      }
    }
    .frame(height: 7 * rowHeight + 6 * Self.gap)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      gridWidth = $0
    }
    .onContinuousHover { phase in
      let slot: Slot? =
        switch phase {
        case .active(let point): slot(at: point)
        case .ended: nil
        }
      if slot != hovered { hovered = slot }
    }
    .accessibilityElement()
    .accessibilityLabel(title)
    .accessibilityValue(peak > 0 ? readout : emptyText)
  }

  private func cellWidth(_ total: CGFloat) -> CGFloat {
    max(1, (total - 23 * Self.gap) / 24)
  }

  /// Rows grow with the columns on a wide window so cells stay close to square, within limits.
  private func cellHeight(_ width: CGFloat) -> CGFloat {
    min(max(width * Self.cellAspect, Self.minCellHeight), Self.maxCellHeight)
  }

  private var rowHeight: CGFloat { cellHeight(cellWidth(gridWidth)) }

  private func slot(at point: CGPoint) -> Slot? {
    guard point.x >= 0, point.y >= 0 else { return nil }
    let hour = Int(point.x / (cellWidth(gridWidth) + Self.gap))
    let day = Int(point.y / (rowHeight + Self.gap))
    guard (0..<24).contains(hour), (0..<7).contains(day) else { return nil }
    return Slot(day: day, hour: hour)
  }

  private func value(_ day: Int, _ hour: Int) -> Int {
    values.indices.contains(day) && values[day].indices.contains(hour) ? values[day][hour] : 0
  }

  /// A floor of ink so the quietest busy hour still reads apart from an empty one.
  private func fill(_ value: Int) -> Color {
    guard value > 0, peak > 0 else { return .token(.selection) }
    let share = Double(value) / Double(peak)
    return SemanticColor.accent.color.opacity(Self.minInk + (1 - Self.minInk) * share)
  }

  private var readout: String {
    guard let hovered else {
      return "Busiest on \(dayName(busiest.day)) around \(hourText(busiest.hour, minutes: true))"
    }
    let when = "\(dayName(hovered.day)) \(hourText(hovered.hour, minutes: true))"
    return "\(value(hovered.day, hovered.hour).formatted()) \(noun) · \(when)"
  }

  /// Monday first, in the user's language.
  private func dayName(_ day: Int) -> String {
    calendar.shortWeekdaySymbols[(day + 1) % 7]
  }

  private func hourText(_ hour: Int, minutes: Bool = false) -> String {
    let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour)) ?? .now
    return minutes ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.hour())
  }

  static var gap: CGFloat { 3 }
  static var minCellHeight: CGFloat { 18 }
  static var maxCellHeight: CGFloat { 26 }
  static var cellAspect: CGFloat { 0.7 }
  static var cellRadius: CGFloat { 3 }
  static var minInk: Double { 0.18 }
  static var hoverRing: Double { 0.5 }
  static var emptyFade: Double { 0.5 }
}
