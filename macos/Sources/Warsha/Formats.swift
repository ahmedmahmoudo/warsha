import Foundation

/// Dates and times in the user's region. Formats are templates ("EEEdMMM"), so the region decides
/// the order and punctuation: "Sat 17 Oct" in Australia, "Sat, Oct 17" in the US.
enum Formats {
  /// The user's region; tests pin it so their expectations hold anywhere.
  nonisolated(unsafe) static var locale = Locale.autoupdatingCurrent

  private static func formatter(_ template: String, zone: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  /// A calendar date (YYYY-MM-DD), which is the same day wherever you are.
  static func day(_ date: String, _ template: String) -> String {
    formatter(template, zone: "UTC").string(from: TodayRules.parseInstant("\(date)T12:00:00Z") ?? Date())
  }

  /// A moment, as it reads in a zone.
  static func instant(_ date: Date, _ template: String, zone: String) -> String {
    formatter(template, zone: zone).string(from: date)
  }

  /// "10:30 am" / "10:30 AM".
  static func time(_ date: Date, zone: String) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: TimeZone(identifier: zone) ?? .current))
  }

  /// "10:00 – 10:30 am", with the region's own way of joining the two.
  static func timeRange(_ from: Date, _ to: Date, zone: String) -> String {
    let interval = DateIntervalFormatter()
    interval.locale = locale
    interval.timeZone = TimeZone(identifier: zone)
    interval.dateStyle = .none
    interval.timeStyle = .short
    return interval.string(from: from, to: to)
  }
}
