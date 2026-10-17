import Foundation

/// A meeting on your primary Google Calendar. Timed ones are UTC ISO instants; all-day ones are
/// YYYY-MM-DD with an exclusive end. shared/calendar.ts in Swift.
struct Meeting: Equatable, Identifiable, Sendable {
  /// What happened to a meeting since Workbench last saw it.
  enum Change: Equatable, Sendable {
    /// Its time moved; `previous*` is the time you last knew it at.
    case rescheduled(previousStart: String, previousEnd: String, at: String)
    /// Gone from your calendar. Kept for a day after `at`, then forgotten.
    case deleted(at: String)

    var at: String {
      switch self {
      case let .rescheduled(_, _, at), let .deleted(at): at
      }
    }

    var isDeleted: Bool { if case .deleted = self { true } else { false } }
  }

  let id: String
  let title: String
  let start: String
  let end: String
  let allDay: Bool
  let joinUrl: String?
  let htmlUrl: String?
  let location: String?
  let declined: Bool
  var change: Change?
}

enum CalendarConnection: Sendable {
  case unconfigured, disconnected, connected
}

/// The saved meetings: server/store/repo.ts's meetings in Swift, on the same table.
extension Store {
  private func meeting(_ row: Database.Row) -> Meeting {
    let change: Meeting.Change? =
      if let deleted = row.string("deleted_at") {
        .deleted(at: deleted)
      } else if let start = row.string("previous_start"), let end = row.string("previous_end"), let at = row.string("rescheduled_at") {
        .rescheduled(previousStart: start, previousEnd: end, at: at)
      } else {
        nil
      }
    return Meeting(
      id: row.string("id")!, title: row.string("title")!, start: row.string("start")!, end: row.string("end")!,
      allDay: row.integer("all_day") == 1, joinUrl: row.string("join_url"), htmlUrl: row.string("html_url"),
      location: row.string("location"), declined: row.integer("declined") == 1, change: change
    )
  }

  func meetings() -> [Meeting] {
    (try? database?.query("select * from meetings order by start").map(meeting)) ?? []
  }

  func meeting(id: String) -> Meeting? {
    (try? database?.query("select * from meetings where id = ?", .text(id)).first).flatMap { $0.map(meeting) }
  }

  /// Saves what Google returned. A new time on a saved meeting marks it rescheduled, remembering the
  /// time you knew; moving back to that time clears the mark. Reappearing undoes a deletion.
  func saveMeeting(_ event: GoogleEvent, at: String) {
    guard let db = database else { return }
    let declined: Int64 = event.response == "declined" ? 1 : 0
    do {
      guard let row = try db.query("select * from meetings where id = ?", .text(event.id)).first else {
        try db.run(
          """
          insert into meetings (id, title, start, end, all_day, join_url, html_url, location, declined, first_seen_at, updated_at)
          values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          .text(event.id), .text(event.title), .text(event.start), .text(event.end), .integer(event.allDay ? 1 : 0),
          .nullable(event.joinUrl), .nullable(event.htmlUrl), .nullable(event.location), .integer(declined), .text(at), .text(at)
        )
        return
      }
      var previousStart = row.string("previous_start")
      var previousEnd = row.string("previous_end")
      var rescheduledAt = row.string("rescheduled_at")
      if row.string("start") != event.start || row.string("end") != event.end {
        if previousStart == nil {
          (previousStart, previousEnd, rescheduledAt) = (row.string("start"), row.string("end"), at)
        } else if previousStart == event.start && previousEnd == event.end {
          (previousStart, previousEnd, rescheduledAt) = (nil, nil, nil)
        } else {
          rescheduledAt = at
        }
      }
      try db.run(
        """
        update meetings set title = ?, start = ?, end = ?, all_day = ?, join_url = ?, html_url = ?, location = ?, declined = ?,
          previous_start = ?, previous_end = ?, rescheduled_at = ?, deleted_at = null, updated_at = ?
        where id = ?
        """,
        .text(event.title), .text(event.start), .text(event.end), .integer(event.allDay ? 1 : 0), .nullable(event.joinUrl),
        .nullable(event.htmlUrl), .nullable(event.location), .integer(declined), .nullable(previousStart), .nullable(previousEnd),
        .nullable(rescheduledAt), .text(at), .text(event.id)
      )
    } catch {}
  }

  /// Marks a saved meeting deleted, keeping when that was first noticed.
  func markMeetingDeleted(_ id: String, at: String) {
    _ = try? database?.run("update meetings set deleted_at = coalesce(deleted_at, ?) where id = ?", .text(at), .text(id))
  }

  func removeMeeting(_ id: String) {
    _ = try? database?.run("delete from meetings where id = ?", .text(id))
  }

  /// Forgets every meeting, for when the Google account is disconnected.
  func clearMeetings() {
    _ = try? database?.run("delete from meetings")
  }

  /// Hides a reschedule notice: the new time becomes the one you know.
  func acknowledgeMeeting(_ id: String) {
    _ = try? database?.run("update meetings set previous_start = null, previous_end = null, rescheduled_at = null where id = ?", .text(id))
  }
}

/// Keeps the saved meetings in step with Google and answers the Today and Calendar pages:
/// server/calendar/sync.ts and route.ts in Swift.
@MainActor
@Observable
final class CalendarModel {
  private static let syncDays = 30
  private static let minSyncInterval: TimeInterval = 60
  private static let day: TimeInterval = 86_400
  /// A deleted meeting stays visible this long after it was noticed, then is forgotten.
  private static let keepDeleted: TimeInterval = 86_400
  /// Saved meetings missing from the list are looked up one by one; this caps the lookups per sync.
  private static let maxLookups = 25
  private static let rangeMaxAge: TimeInterval = 30

  private(set) var lastSync: (at: Date, error: String?)?
  /// Bumped whenever the saved meetings change, so views reading them refresh.
  private(set) var revision = 0
  private(set) var signingIn = false
  private var syncing: Task<Void, Never>?
  private var ranges: [String: (at: Date, meetings: [Meeting])] = [:]

  // MARK: Connection

  /// Your own Google client when Settings has one, otherwise the one built into the app.
  private func client(_ settings: AppSettings) -> GoogleCalendar.Client? {
    if !settings.googleClientId.isEmpty, !settings.googleClientSecret.isEmpty {
      return GoogleCalendar.Client(id: settings.googleClientId, secret: settings.googleClientSecret)
    }
    return Self.builtInClient
  }

  /// Workbench's own client, baked in at build time (macos/Secrets.xcconfig); nil in builds without one.
  static var builtInClient: GoogleCalendar.Client? {
    guard let id = Bundle.main.object(forInfoDictionaryKey: "WorkbenchGoogleClientId") as? String, !id.isEmpty,
          let secret = Bundle.main.object(forInfoDictionaryKey: "WorkbenchGoogleClientSecret") as? String, !secret.isEmpty
    else { return nil }
    return GoogleCalendar.Client(id: id, secret: secret)
  }

  /// The refresh token, moved into the Keychain from an imported web database the first time.
  private func refreshToken(_ store: Store) -> String? {
    if let token = Keychain.get(GoogleCalendar.refreshTokenKey) { return token }
    guard let legacy = store.setting(GoogleCalendar.legacyRefreshTokenSetting) else { return nil }
    Keychain.set(GoogleCalendar.refreshTokenKey, legacy)
    store.setSetting(GoogleCalendar.legacyRefreshTokenSetting, nil)
    return legacy
  }

  func connection(_ settings: AppSettings, _ store: Store) -> CalendarConnection {
    client(settings) == nil ? .unconfigured : refreshToken(store) == nil ? .disconnected : .connected
  }

  func email(_ store: Store) -> String? { store.setting(GoogleCalendar.emailSetting) }

  func signIn(_ settings: AppSettings, _ store: Store) async throws {
    guard let client = client(settings) else { throw NotConfigured("Add the Google client ID and secret first.") }
    signingIn = true
    defer { signingIn = false }
    let (token, email) = try await GoogleCalendar.shared.signIn(client: client)
    Keychain.set(GoogleCalendar.refreshTokenKey, token)
    store.setSetting(GoogleCalendar.emailSetting, email)
    // The first sync saves what's on your calendar now: the baseline later changes are measured from.
    await sync(settings, store, force: true)
  }

  /// Forgets the account here and revokes Workbench's access at Google.
  func disconnect(_ store: Store) async {
    let token = refreshToken(store)
    Keychain.set(GoogleCalendar.refreshTokenKey, nil)
    store.setSetting(GoogleCalendar.emailSetting, nil)
    // Another account's meetings would all look deleted; start over on the next connect.
    store.clearMeetings()
    ranges = [:]
    lastSync = nil
    revision += 1
    if let token { await GoogleCalendar.shared.revoke(refreshToken: token) }
  }

  /// Calls Google with the stored token; a revoked one is forgotten so Settings asks to reconnect.
  private func withGoogle<T>(_ settings: AppSettings, _ store: Store, _ work: (GoogleCalendar.Client, String) async throws -> T) async throws -> T {
    guard let client = client(settings), let token = refreshToken(store) else { throw NotConfigured("Google Calendar isn't connected.") }
    do {
      return try await work(client, token)
    } catch is GoogleCalendar.Revoked {
      Keychain.set(GoogleCalendar.refreshTokenKey, nil)
      store.setSetting(GoogleCalendar.emailSetting, nil)
      revision += 1
      throw GoogleCalendar.Revoked()
    }
  }

  // MARK: Sync

  /// From the start of today to 30 days ahead, every meeting Google returns is saved (a new time
  /// marks it rescheduled), and a saved one Google no longer has is marked deleted. At most once a
  /// minute unless forced.
  func sync(_ settings: AppSettings, _ store: Store, force: Bool = false) async {
    guard connection(settings, store) == .connected else { return }
    if !force, let lastSync, -lastSync.at.timeIntervalSinceNow < Self.minSyncInterval { return }
    if let syncing { return await syncing.value }
    let task = Task {
      do {
        try await run(settings, store)
        lastSync = (Date(), nil)
      } catch {
        lastSync = (Date(), error.localizedDescription)
      }
      revision += 1
    }
    syncing = task
    await task.value
    syncing = nil
  }

  private func run(_ settings: AppSettings, _ store: Store) async throws {
    let now = Date()
    let at = Store.timestamp(now)
    let zone = settings.timeZone
    let from = CalendarTime.startOfDate(TodayRules.localDate(now, zone), zone)
    let to = from.addingTimeInterval(Double(Self.syncDays) * Self.day)

    let events = try await withGoogle(settings, store) { client, token in
      try await GoogleCalendar.shared.events(
        from: Store.timestamp(from), to: Store.timestamp(to), showDeleted: true, client: client, refreshToken: token
      )
    }
    var returned = Set<String>()
    for event in events {
      returned.insert(event.id)
      // A cancelled event only matters if you'd seen it; one never saved stays unknown.
      if event.cancelled { store.markMeetingDeleted(event.id, at: at) } else { store.saveMeeting(event, at: at) }
    }

    // Saved and due in the window, yet not returned at all: deleted outright, or moved out of the window.
    let missing = store.meetings().filter {
      !($0.change?.isDeleted ?? false) && !returned.contains($0.id) && CalendarTime.overlaps($0, from: from, to: to, zone: zone)
    }
    for meeting in missing.prefix(Self.maxLookups) {
      let event = try await withGoogle(settings, store) { client, token in
        try await GoogleCalendar.shared.event(id: meeting.id, client: client, refreshToken: token)
      }
      if let event, !event.cancelled { store.saveMeeting(event, at: at) } else { store.markMeetingDeleted(meeting.id, at: at) }
    }

    // Forget meetings that are over, and deletions shown for long enough.
    for meeting in store.meetings() {
      let expired = if case let .deleted(deletedAt) = meeting.change {
        now.timeIntervalSince(TodayRules.parseInstant(deletedAt) ?? now) > Self.keepDeleted
      } else {
        CalendarTime.endsAt(meeting, zone: zone) < from
      }
      if expired { store.removeMeeting(meeting.id) }
    }
  }

  // MARK: What the pages read

  /// Today's meetings in the home zone, in time order; deleted ones are under `changes` instead.
  func today(_ settings: AppSettings, _ store: Store) -> [Meeting] {
    _ = revision
    let zone = settings.timeZone
    let from = CalendarTime.startOfDate(TodayRules.localDate(Date(), zone), zone)
    return store.meetings()
      .filter { !($0.change?.isDeleted ?? false) && CalendarTime.overlaps($0, from: from, to: from.addingTimeInterval(Self.day), zone: zone) }
      .sorted { $0.start < $1.start }
  }

  /// Rescheduled and deleted meetings, any day, newest change first, until dismissed.
  func changes(_ store: Store) -> [Meeting] {
    _ = revision
    return TodayRules.stableSorted(store.meetings().filter { $0.change != nil }) { ($0.change?.at ?? "") > ($1.change?.at ?? "") }
  }

  /// Every meeting overlapping [from, to), read live from Google (kept 30 seconds), with change
  /// marks from the saved ones; deleted meetings come from the saved copies until forgotten.
  func range(from: Date, to: Date, settings: AppSettings, store: Store, force: Bool = false) async throws -> [Meeting] {
    await sync(settings, store, force: force)
    let key = "\(Store.timestamp(from))|\(Store.timestamp(to))"
    var live: [Meeting]
    if !force, let cached = ranges[key], -cached.at.timeIntervalSinceNow < Self.rangeMaxAge {
      live = cached.meetings
    } else {
      live = try await withGoogle(settings, store) { client, token in
        try await GoogleCalendar.shared.events(from: Store.timestamp(from), to: Store.timestamp(to), client: client, refreshToken: token)
      }.map {
        Meeting(
          id: $0.id, title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay, joinUrl: $0.joinUrl, htmlUrl: $0.htmlUrl,
          location: $0.location, declined: $0.response == "declined", change: nil
        )
      }
      ranges[key] = (Date(), live)
    }
    let saved = Dictionary(store.meetings().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for index in live.indices { live[index].change = saved[live[index].id]?.change }
    var ids = Set(live.map(\.id))
    for meeting in saved.values where meeting.change?.isDeleted == true && CalendarTime.overlaps(meeting, from: from, to: to, zone: settings.timeZone) {
      if ids.insert(meeting.id).inserted { live.append(meeting) }
    }
    return TodayRules.stableSorted(live) { $0.start < $1.start }
  }

  /// Dismisses a change: a reschedule becomes the known time; a deleted meeting is forgotten now.
  func dismiss(_ meeting: Meeting, _ store: Store) {
    guard let change = store.meeting(id: meeting.id)?.change else { return }
    if change.isDeleted { store.removeMeeting(meeting.id) } else { store.acknowledgeMeeting(meeting.id) }
    revision += 1
  }
}

/// Dates and times in a zone, for meetings: server/activity/week.ts and src/components/calendar/time.ts.
enum CalendarTime {
  static func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone) ?? .current
    return calendar
  }

  /// The instant a calendar date starts in the zone, allowing for daylight saving.
  static func startOfDate(_ date: String, _ zone: String) -> Date {
    let parts = date.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return Date() }
    return calendar(zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
  }

  /// When a meeting starts and ends; all-day dates count from their start of day in the zone.
  static func startsAt(_ meeting: Meeting, zone: String) -> Date {
    meeting.allDay ? startOfDate(meeting.start, zone) : TodayRules.parseInstant(meeting.start) ?? .distantPast
  }

  static func endsAt(_ meeting: Meeting, zone: String) -> Date {
    meeting.allDay ? startOfDate(meeting.end, zone) : TodayRules.parseInstant(meeting.end) ?? .distantPast
  }

  static func overlaps(_ meeting: Meeting, from: Date, to: Date, zone: String) -> Bool {
    startsAt(meeting, zone: zone) < to && endsAt(meeting, zone: zone) > from
  }

  /// The calendar date and minute of the day an instant falls on in a zone.
  static func zoned(_ iso: String, _ zone: String) -> (date: String, minutes: Int) {
    let instant = TodayRules.parseInstant(iso) ?? Date()
    let parts = calendar(zone).dateComponents([.year, .month, .day, .hour, .minute], from: instant)
    return (String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), parts.hour! * 60 + parts.minute!)
  }

  /// The days a meeting covers in a zone (all-day ones by their own dates, whatever the zone).
  static func days(_ meeting: Meeting, zone: String) -> (first: String, last: String) {
    if meeting.allDay { return (meeting.start, TodayRules.addDays(meeting.end, -1)) }
    let end = zoned(meeting.end, zone)
    let first = zoned(meeting.start, zone).date
    // Ending exactly at midnight belongs to the day before.
    let last = end.minutes == 0 && end.date > first ? TodayRules.addDays(end.date, -1) : end.date
    return (first, last)
  }

  static func onDay(_ meeting: Meeting, _ day: String, zone: String) -> Bool {
    let (first, last) = days(meeting, zone: zone)
    return first <= day && day <= last
  }

  /// "Australia/Sydney" → "Sydney".
  static func city(_ zone: String) -> String {
    (zone.split(separator: "/").last.map(String.init) ?? zone).replacingOccurrences(of: "_", with: " ")
  }

  /// "9:30 am" in Australia.
  static func clock(_ iso: String, _ zone: String) -> String {
    Formats.time(TodayRules.parseInstant(iso) ?? Date(), zone: zone)
  }

  /// "10:00 – 10:30 am", "Tue 20 Oct, 10:00 – 10:30 am" with `withDay`, or "All day".
  static func timeRange(start: String, end: String, allDay: Bool, zone: String, withDay: Bool) -> String {
    if allDay {
      return withDay ? "\(Formats.day(start, "EEEdMMM")), all day" : "All day"
    }
    let from = TodayRules.parseInstant(start) ?? Date()
    let range = Formats.timeRange(from, TodayRules.parseInstant(end) ?? Date(), zone: zone)
    return withDay ? "\(Formats.instant(from, "EEEdMMM", zone: zone)), \(range)" : range
  }
}
