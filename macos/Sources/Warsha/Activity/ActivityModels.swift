import Foundation

// What the Activity page shows: shared/activity.ts in Swift.

struct ActivityPr: Equatable, Sendable {
  enum State: String, Decodable, Sendable { case OPEN, CLOSED, MERGED }
  let repo: String
  let number: Int
  let title: String
  let url: String
  let author: Person?
  let state: State
  let isDraft: Bool
  let createdAt: String
  let mergedAt: String?
  let headRef: String
  var ticketKeys: [String]
}

enum DayEntryKind: String, Sendable {
  case pushed, opened, merged, closed, reopened, replied, commented, approved
  case changesRequested = "changes-requested", reviewed, ticket
}

struct DayEntry: Equatable, Sendable {
  var kind: DayEntryKind
  var at: String
  /// What happened, ready to show: "pushed 3×", "opened #18771", "moved to In Review".
  var text: String
  var url: String?
}

/// One ticket's (or one branch's) work on one day.
struct DayGroup: Equatable, Identifiable, Sendable {
  let key: String
  let ticket: Ticket?
  /// The ticket title, else the PR title or branch name.
  let title: String
  let entries: [DayEntry]
  var id: String { key }
}

struct DayReview: Equatable, Sendable {
  let entry: DayEntry
  let pr: ActivityPr
}

struct ActivityDay: Equatable, Sendable {
  /// YYYY-MM-DD in the page's time zone.
  let date: String
  let groups: [DayGroup]
  /// Reviews of other people's PRs that day.
  let reviews: [DayReview]
  /// False when the day is older than GitHub's events feed: no pushes or replies, only PR and ticket facts.
  let detailed: Bool
}

struct ReviewGiven: Equatable, Sendable {
  struct Review: Equatable, Sendable { let state: String; let at: String; let url: String; let comments: Int }
  let pr: ActivityPr
  let reviews: [Review]
}

struct TicketTransition: Equatable, Sendable {
  let at: String
  let from: String?
  let to: String
  let toType: String
  let by: String?
}

struct TicketActivity: Equatable, Sendable {
  let ticket: Ticket
  /// You created it in the range.
  let created: Bool
  let transitions: [TicketTransition]
}

struct ShippedPr: Equatable, Sendable {
  let pr: ActivityPr
  let tickets: [Ticket]
  /// Merged, but its ticket isn't marked done yet.
  let ticketLagging: Bool
}

/// How much of the range GitHub's events feed covers. It keeps about 300 events, so day-by-day
/// detail (pushes, replies) only reaches back a couple of weeks; PR facts come from search.
enum DayByDayCoverage: String, Sendable { case complete, partial, unavailable }

/// A PR linked to a ticket, with the PR list's plain-words status while it's open.
struct LinkedPr: Equatable, Sendable {
  let pr: ActivityPr
  let status: PrStatus?
}

enum ActivitySpan: String, CaseIterable, Identifiable, Sendable {
  case day, week, month
  var id: Self { self }
  var label: String { rawValue.capitalized }
}

/// A span of whole calendar days in a zone; `from` is inclusive and `to` exclusive.
struct ActivityRange: Hashable, Sendable {
  let span: ActivitySpan
  /// First and last day (inclusive), YYYY-MM-DD.
  let start: String
  let end: String
  let from: Date
  let to: Date
  let timeZone: String
  /// Today falls inside it.
  let isCurrent: Bool

  /// The day, the Monday-to-Sunday week, or the calendar month containing `date`.
  init(_ span: ActivitySpan, date: String, timeZone: String, now: Date = Date()) {
    let start = switch span {
    case .day: date
    case .week: ActivityDates.monday(date)
    case .month: "\(date.prefix(7))-01"
    }
    let end = switch span {
    case .day: date
    case .week: TodayRules.addDays(start, 6)
    case .month: TodayRules.addDays(ActivityDates.addMonths(start, 1), -1)
    }
    let today = TodayRules.localDate(now, timeZone)
    self.span = span
    self.start = start
    self.end = end
    from = CalendarTime.startOfDate(start, timeZone)
    to = CalendarTime.startOfDate(TodayRules.addDays(end, 1), timeZone)
    self.timeZone = timeZone
    isCurrent = start <= today && today <= end
  }
}

struct ActivityTotals: Equatable, Sendable {
  let prsOpened: Int
  let prsMerged: Int
  /// Other people's PRs you reviewed.
  let prsReviewed: Int
  let ticketsCompleted: Int
  /// Nil when the events feed doesn't cover the whole range.
  let pushes: Int?
}

struct ActivityData: Sendable {
  let range: ActivityRange
  let viewer: String
  let totals: ActivityTotals
  let dayByDay: DayByDayCoverage
  /// The oldest moment the events feed covers.
  let coverageFrom: String?
  let days: [ActivityDay]
  let shipped: [ShippedPr]
  let opened: [ActivityPr]
  let reviewsGiven: [ReviewGiven]
  let tickets: [TicketActivity]
  /// Day view only: linked PRs per ticket key in the day.
  let ticketCards: [String: [LinkedPr]]
  /// How long each in-flight ticket in the range has sat in its status, as of now.
  let ticketAges: [String: TicketAge]
  let warnings: [String]
  let fetchedAt: Date
}

/// Calendar maths on YYYY-MM-DD strings, as src/components/activity/calendar.ts does it.
enum ActivityDates {
  private static func noon(_ date: String) -> Date { TodayRules.parseInstant("\(date)T12:00:00Z") ?? Date() }

  /// The Monday on or before the date.
  static func monday(_ date: String) -> String {
    let weekday = CalendarTime.calendar("UTC").component(.weekday, from: noon(date))
    return TodayRules.addDays(date, -((weekday + 5) % 7))
  }

  static func addMonths(_ date: String, _ months: Int) -> String {
    let moved = CalendarTime.calendar("UTC").date(byAdding: .month, value: months, to: noon("\(date.prefix(7))-01"))!
    return TodayRules.localDate(moved, "UTC")
  }

  /// The date to move to for the previous or next day, week or month.
  static func step(_ span: ActivitySpan, _ date: String, _ by: Int) -> String {
    switch span {
    case .day: TodayRules.addDays(date, by)
    case .week: TodayRules.addDays(date, 7 * by)
    case .month: addMonths(date, by)
    }
  }

  /// Every day from the Monday before the 1st to the Sunday after the last, in weeks.
  static func monthGrid(_ start: String, _ end: String) -> [[String]] {
    var weeks: [[String]] = []
    var day = monday(start)
    while day <= end {
      weeks.append((0 ..< 7).map { TodayRules.addDays(day, $0) })
      day = TodayRules.addDays(day, 7)
    }
    return weeks
  }

  /// A date with a template, in the user's region.
  static func format(_ date: String, _ template: String) -> String { Formats.day(date, template) }

  /// "Sat 17 Oct 2026", "12 Oct – 18 Oct 2026", "October 2026" (in Australia), in the user's region.
  static func label(_ span: ActivitySpan, _ start: String, _ end: String) -> String {
    switch span {
    case .day: format(start, "EEEdMMMyyyy")
    case .month: format(start, "MMMMyyyy")
    case .week: "\(format(start, "dMMM")) – \(format(end, "dMMMyyyy"))"
    }
  }
}
