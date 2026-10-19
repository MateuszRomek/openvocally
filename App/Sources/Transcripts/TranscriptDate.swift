import Foundation

/// How Transcripts names a transcript's date, compact in a row the way Mail's list does. Formats
/// with the calendar's locale and time zone.
enum TranscriptDate {
  /// The time today, the localized word for yesterday, the weekday within the last six days, else the day and month, with
  /// the year when it is not this year.
  static func compact(_ date: Date, now: Date = .now, calendar: Calendar) -> String {
    let style = base(calendar)
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style.hour().minute()) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return Date.AnchoredRelativeFormatStyle(
        anchor: date, allowedFields: [.day], presentation: .named, unitsStyle: .wide,
        locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
        capitalizationContext: .beginningOfSentence
      ).format(now)
    }
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
    ).day
    if let days, days > 0, days <= 6 { return date.formatted(style.weekday(.wide)) }
    let dayMonth = style.day().month(.abbreviated)
    if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(dayMonth) }
    return date.formatted(dayMonth.year())
  }

  /// The weekday, day and month, with the year when it is not this year, then the time.
  static func full(_ date: Date, now: Date = .now, calendar: Calendar) -> String {
    let style = base(calendar)
    let day = style.weekday(.wide).day().month(.wide)
    let time = date.formatted(style.hour().minute())
    let dayText =
      calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? date.formatted(day) : date.formatted(day.year())
    return "\(dayText) · \(time)"
  }

  private static func base(_ calendar: Calendar) -> Date.FormatStyle {
    Date.FormatStyle(
      locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
  }
}
