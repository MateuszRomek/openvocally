import Charts
import SwiftUI

/// One point of a `TimeChart`: the start of its day, week or month, and its value.
public struct TimePoint: Identifiable, Equatable, Sendable {
  public let start: Date
  public let value: Double

  public var id: Date { start }

  public init(start: Date, value: Double) {
    self.start = start
    self.value = value
  }
}

/// Values over time, one per day, week or month, under a title. An area in `accent` ink, or
/// bars with history in faded ink and the current period in full ink. The title's second line
/// names the average, and the area also marks it with a dashed line over the data, so no label
/// sits on a mark. Hovering a period names its value in that line instead. The accessory, such as a range picker,
/// sits at the title's right.
public struct TimeChart<Accessory: View>: View {
  public enum Style: Sendable {
    /// Words over many periods. Reads as a trend.
    case area
    /// Few periods, each compared with the others.
    case bars
  }

  let title: String
  let points: [TimePoint]
  let unit: Calendar.Component
  let style: Style
  /// Names the value, such as "words".
  let noun: String
  /// The title's second line while nothing is hovered, such as the total.
  let detail: String
  /// Shown in place of the plot when no point has a value above zero.
  let emptyText: String
  let accessory: Accessory

  @State private var hovered: Date?
  @Environment(\.calendar) private var calendar

  public init(
    _ title: String, points: [TimePoint], unit: Calendar.Component, style: Style, noun: String,
    detail: String, emptyText: String, @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.points = points
    self.unit = unit
    self.style = style
    self.noun = noun
    self.detail = detail
    self.emptyText = emptyText
    self.accessory = accessory()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Space.m.points) {
      HStack(alignment: .firstTextBaseline) {
        SectionHeader(title: title, detail: hasData ? readout : nil)
        Spacer(minLength: Space.s.points)
        accessory
      }
      Group {
        if hasData {
          chart
        } else {
          placeholder
        }
      }
      .frame(height: Self.plotHeight)
    }
  }

  /// Leaves room for about four gridlines and the axis labels.
  static var plotHeight: CGFloat { 168 }

  private var hasData: Bool { values.contains { $0 > 0 } }

  private var values: [Double] { points.map(\.value) }

  private var average: Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }

  private var ink: Color { SemanticColor.accent.color }

  private var chart: some View {
    Chart {
      switch style {
      case .area: area
      case .bars: bars
      }
      if let average, points.count > 1, style == .area {
        RuleMark(y: .value("Average", average))
          .foregroundStyle(Color.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .zIndex(1)
          .accessibilityLabel("Average")
          .accessibilityValue(valueText(average))
      }
      if let hoveredPoint, style != .bars {
        RuleMark(x: .value("Period", hoveredPoint.start, unit: unit))
          .foregroundStyle(.token(.separator))
        PointMark(x: .value("Period", hoveredPoint.start, unit: unit), y: .value(noun, hoveredPoint.value))
          .foregroundStyle(ink)
          .symbolSize(Self.dotSize)
          .zIndex(2)
      }
    }
    .chartXSelection(value: $hovered)
    .chartXAxis {
      AxisMarks(values: axisValues) { _ in
        AxisValueLabel(format: axisFormat, centered: style == .bars)
          .foregroundStyle(Color.secondary)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine().foregroundStyle(.token(.separator))
        AxisValueLabel(format: FloatingPointFormatStyle<Double>().notation(.compactName))
          .foregroundStyle(Color.secondary.opacity(Self.axisInk))
      }
    }
  }

  @ChartContentBuilder private var area: some ChartContent {
    ForEach(points) { point in
      AreaMark(
        x: .value("Period", point.start, unit: unit), y: .value(noun.capitalized, point.value)
      )
      .interpolationMethod(.monotone)
      .foregroundStyle(
        LinearGradient(
          colors: [ink.opacity(Self.areaTop), ink.opacity(0)], startPoint: .top, endPoint: .bottom))
      LineMark(
        x: .value("Period", point.start, unit: unit), y: .value(noun.capitalized, point.value)
      )
      .interpolationMethod(.monotone)
      .foregroundStyle(ink)
      .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
      .accessibilityLabel(periodText(point.start))
      .accessibilityValue(valueText(point.value))
    }
  }

  @ChartContentBuilder private var bars: some ChartContent {
    ForEach(points) { point in
      BarMark(
        x: .value("Period", point.start, unit: unit), y: .value(noun.capitalized, point.value),
        width: .ratio(Self.barWidth)
      )
      .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.barRadius, topTrailingRadius: Self.barRadius))
      .foregroundStyle(barInk(for: point))
      .accessibilityLabel(periodText(point.start))
      .accessibilityValue(valueText(point.value))
    }
  }

  /// The current period in full ink, history faded, so the eye lands on now. Hovering a bar
  /// gives it full ink and fades the rest further.
  private func barInk(for point: TimePoint) -> Color {
    if let hoveredPoint { return hoveredPoint == point ? ink : ink.opacity(Self.fadedInk) }
    return point == points.last ? ink : ink.opacity(Self.pastInk)
  }

  /// A skeleton of bars behind the empty message, so the card keeps its shape and reads as a
  /// chart waiting for data rather than a missing one.
  private var placeholder: some View {
    ZStack {
      GeometryReader { proxy in
        HStack(alignment: .bottom, spacing: Space.s.points) {
          ForEach(Array(Self.skeleton.enumerated()), id: \.offset) { _, height in
            UnevenRoundedRectangle(topLeadingRadius: Self.barRadius, topTrailingRadius: Self.barRadius)
              .fill(.token(.selection))
              .frame(maxWidth: .infinity)
              .frame(height: proxy.size.height * height)
          }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .mask(LinearGradient(colors: [.clear, .primary], startPoint: .top, endPoint: .bottom))
      Text(emptyText)
        .textStyle(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(emptyText)
  }

  /// The hovered period, else the caller's detail and the average.
  private var readout: String {
    if let hoveredPoint {
      return "\(valueText(hoveredPoint.value)) · \(periodText(hoveredPoint.start))"
    }
    guard let average, points.count > 1 else { return detail }
    return "\(detail) · avg \(compact(average))"
  }

  private var hoveredPoint: TimePoint? {
    guard let hovered, let interval = calendar.dateInterval(of: unit, for: hovered) else { return nil }
    return points.first { interval.contains($0.start) }
  }

  private func compact(_ value: Double) -> String {
    value < 1000
      ? value.formatted(.number.precision(.fractionLength(0)))
      : value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
  }

  private func valueText(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)))) \(noun)"
  }

  private func periodText(_ start: Date) -> String {
    switch unit {
    case .month: start.formatted(.dateTime.month(.wide).year())
    case .weekOfYear: "Week of \(start.formatted(.dateTime.month(.abbreviated).day()))"
    default: start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
  }

  /// Every period up to a dozen, else about six labels.
  private var axisValues: AxisMarkValues {
    if points.count <= 12 { return .stride(by: unit, count: 1) }
    return .stride(by: unit, count: Int((Double(points.count) / 6).rounded(.up)))
  }

  private var axisFormat: Date.FormatStyle {
    switch unit {
    case .month: .dateTime.month(.narrow)
    case .day where points.count <= 7: .dateTime.weekday(.abbreviated)
    default: .dateTime.month(.abbreviated).day()
    }
  }

  private static var skeleton: [Double] {
    [0.35, 0.55, 0.42, 0.7, 0.5, 0.82, 0.6, 0.45, 0.66, 0.38, 0.58, 0.48]
  }
  static var barRadius: CGFloat { 4 }
  static var barWidth: Double { 0.62 }
  static var lineWidth: CGFloat { 2 }
  static var dotSize: CGFloat { 64 }
  static var areaTop: Double { 0.16 }
  static var axisInk: Double { 0.6 }
  static var pastInk: Double { 0.3 }
  static var fadedInk: Double { 0.12 }
}

extension TimeChart where Accessory == EmptyView {
  public init(
    _ title: String, points: [TimePoint], unit: Calendar.Component, style: Style, noun: String,
    detail: String, emptyText: String
  ) {
    self.init(
      title, points: points, unit: unit, style: style, noun: noun, detail: detail, emptyText: emptyText
    ) { EmptyView() }
  }
}
