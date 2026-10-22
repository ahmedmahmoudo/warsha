import AppKit
import SwiftUI

/// A calendar of what you did: Day, Week or Month, in your home zone or this Mac's.
/// src/routes/ActivityPage.tsx and components/activity/views.tsx in SwiftUI.
struct ActivityView: View {
  enum ZoneChoice: String { case home, local }

  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @AppStorage("activitySpan") private var span: ActivitySpan = .week
  @AppStorage("activityZone") private var zoneChoice: ZoneChoice = .home
  @State private var date: String? = DevHooks.startDate
  @Environment(ActivityModel.self) private var model

  private var zone: String { zoneChoice == .local ? TimeZone.current.identifier : settings.timeZone }
  private var today: String { TodayRules.localDate(Date(), zone) }
  private var current: String { date ?? today }
  private var range: ActivityRange { ActivityRange(span, date: current, timeZone: zone) }

  var body: some View {
    PageScrollView {
      VStack(alignment: .leading, spacing: 12) {
        controls
        if let error = model.error {
          Label(error is NotConfigured ? "Setup needed: \(error.localizedDescription)" : error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Tone.bad.color)
        }
        // The range asked for if it's been loaded, else the last one shown, dimmed until it arrives.
        if let data = model.data(for: range) ?? model.data {
          content(data).opacity(data.range != range ? 0.5 : 1)
        } else if model.error == nil {
          SkeletonPanel(title: "Activity", rows: 5)
        }
      }
      .padding(.horizontal, 20).padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .warshaPage()
    .navigationTitle("Activity")
    .navigationSubtitle(model.loading ? "Updating…" : model.data(for: range).map { "Updated at \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" } ?? "")
    .toolbar {
      ToolbarItemGroup {
        if let data = model.data(for: range) { CopySummaryButton(data: data) }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load(range, settings: settings) } }
          .clickable()
          .keyboardShortcut("r")
          .disabled(model.loading)
      }
    }
    .task(id: "\(span.rawValue)|\(current)|\(zone)") {
      while !Task.isCancelled {
        // What you did changes slowly, and its searches are the costliest to repeat.
        await model.load(range, settings: settings, maxAge: .seconds(300))
        try? await Task.sleep(for: .seconds(300))
      }
    }
  }

  private var controls: some View {
    let next = ActivityDates.step(span, current, 1)
    // Moving forward only makes sense once the next range has started.
    let canGoForward = span == .month ? next.prefix(7) <= today.prefix(7) : next <= today
    return HStack(spacing: 12) {
      Picker("View", selection: $span) {
        ForEach(ActivitySpan.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize().focusEffectDisabled()
      HStack(spacing: 4) {
        Button("Earlier", systemImage: "chevron.left") { date = ActivityDates.step(span, current, -1) }
          .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().keyboardShortcut(.leftArrow, modifiers: .command)
        Text(ActivityDates.label(span, range.start, range.end)).scaledFont(.headline).monospacedDigit().scaledFrame(minWidth: 180)
        Button("Later", systemImage: "chevron.right") { date = next }
          .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().disabled(!canGoForward).keyboardShortcut(.rightArrow, modifiers: .command)
        if !range.isCurrent {
          Button("Today") { date = nil }.scaledControlSize(.small).clickable().keyboardShortcut("t", modifiers: .command)
        }
      }
      Spacer()
      Picker("Time zone", selection: $zoneChoice) {
        Text(CalendarTime.city(settings.timeZone)).tag(ZoneChoice.home)
        Text(TimeZone.current.identifier == settings.timeZone ? "Local" : "Local · \(CalendarTime.city(TimeZone.current.identifier))").tag(ZoneChoice.local)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize().focusEffectDisabled()
    }
  }

  @ViewBuilder
  private func content(_ data: ActivityData) -> some View {
    HStack(spacing: 12) {
      TotalsLine(totals: data.totals)
      AttentionSummary(data: data)
      Spacer()
      if data.dayByDay != .complete {
        Label("Pushes and replies only reach back a few weeks", systemImage: "info.circle")
          .scaledFont(.caption).foregroundStyle(.tertiary)
          .help(data.warnings.joined(separator: "\n"))
      }
    }
    ForEach(data.warnings.filter { !$0.hasPrefix("Pushes and replies") && !$0.hasPrefix("No pushes or replies") }, id: \.self) {
      Label($0, systemImage: "info.circle").scaledFont(.caption).foregroundStyle(Tone.warn.color)
    }
    switch data.range.span {
    case .month: MonthActivity(data: data) { openDay($0) }
    case .week: WeekActivity(data: data) { openDay($0) }
    case .day: DayActivity(data: data)
    }
  }

  private func openDay(_ day: String) {
    span = .day
    date = day
  }
}

@MainActor
@Observable
final class ActivityModel {
  /// Ranges kept, so going back to a week or month you've seen shows it at once.
  private static let rangesKept = 12

  /// The last range loaded.
  private(set) var data: ActivityData?
  private(set) var error: (any Error)?
  private(set) var loading = false
  private var byRange: [ActivityRange: ActivityData] = [:]

  func data(for range: ActivityRange) -> ActivityData? { byRange[range] }

  /// `maxAge` skips the load when that range's answer is at least that recent.
  func load(_ range: ActivityRange, settings: AppSettings, maxAge: Duration? = nil) async {
    if let maxAge, let cached = byRange[range], Date().timeIntervalSince(cached.fetchedAt) < Double(maxAge.components.seconds) {
      data = cached
      return
    }
    if maxAge != nil, let cached = byRange[range], RateBudget.shared.lowUntil != nil {
      data = cached
      return
    }
    loading = true
    defer { loading = false }
    do {
      let loaded = try await ActivityService.shared.build(range, config: PrConfig(settings))
      data = loaded
      byRange[range] = loaded
      if byRange.count > Self.rangesKept, let oldest = byRange.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
        byRange[oldest] = nil
      }
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = error
    }
  }
}

// MARK: Summary and totals

/// A paste-ready summary for a standup or update, covering whatever range is shown.
func activitySummary(_ data: ActivityData) -> String {
  // "fix(MX-2475): rename…" becomes "MX-2475: rename…": the ticket says what the prefix did.
  func line(_ pr: ActivityPr) -> String {
    guard let key = pr.ticketKeys.first else { return "\(pr.title) (#\(pr.number))" }
    let title = pr.title.replacingOccurrences(of: #"^\w+(\([^)]*\))?!?:\s*"#, with: "", options: .regularExpression)
    return "\(key): \(title) (#\(pr.number))"
  }
  let label = ActivityDates.label(data.range.span, data.range.start, data.range.end)
  let inReview = data.opened.filter { $0.state == .OPEN }
  let sections: [String?] = [
    "*\(data.range.span == .week ? "Week of \(label)" : label)*",
    data.shipped.isEmpty ? nil : (["*Shipped*"] + data.shipped.map { "• \(line($0.pr))" }).joined(separator: "\n"),
    inReview.isEmpty ? nil : (["*In review*"] + inReview.map { "• \(line($0))" }).joined(separator: "\n"),
    data.reviewsGiven.isEmpty ? nil : (["*Reviewed*"] + data.reviewsGiven.map {
      "• \($0.pr.title) (#\($0.pr.number)\($0.pr.author.map { " by \($0.name)" } ?? ""))"
    }).joined(separator: "\n"),
    data.totals.ticketsCompleted > 0 ? "\(data.totals.ticketsCompleted) ticket\(data.totals.ticketsCompleted == 1 ? "" : "s") completed." : nil,
  ]
  return sections.compactMap { $0 }.joined(separator: "\n\n")
}

private struct CopySummaryButton: View {
  let data: ActivityData
  @State private var copied = false

  var body: some View {
    Button(copied ? "Copied" : "Copy Summary", systemImage: copied ? "checkmark" : "doc.on.clipboard") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(activitySummary(data), forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(2))
        copied = false
      }
    }
    .clickable()
    .help("Copy a paste-ready summary of this range")
  }
}

/// One quiet line of totals rather than a row of cards.
private struct TotalsLine: View {
  let totals: ActivityTotals

  var body: some View {
    let parts = ["\(totals.prsMerged) merged", "\(totals.prsOpened) opened", "\(totals.prsReviewed) reviewed", "\(totals.ticketsCompleted) tickets done"]
      + (totals.pushes.map { ["\($0) pushes"] } ?? [])
    Text(parts.joined(separator: " · ")).scaledFont(.callout).foregroundStyle(.secondary)
  }
}

/// "1 stuck · 3 getting slow", naming the tickets on hover; nothing when all is well.
private struct AttentionSummary: View {
  let data: ActivityData
  @Environment(Store.self) private var store

  var body: some View {
    let ages = data.ticketAges.filter { store.activeParked(ticketRef($0.key)) == nil }.sorted { $0.key < $1.key }
    let stuck = ages.filter { $0.value.level == .alert }
    let slow = ages.filter { $0.value.level == .warn }
    HStack(spacing: 6) {
      if !stuck.isEmpty {
        Label("\(stuck.count) stuck", systemImage: "exclamationmark.triangle").scaledFont(.caption.weight(.medium)).foregroundStyle(Tone.bad.color)
          .padding(.horizontal, 6).padding(.vertical, 2).background(Tone.bad.soft, in: .rect(cornerRadius: 5))
          .help(stuck.map { "\($0.key): \($0.value.message ?? "")" }.joined(separator: "\n"))
      }
      if !slow.isEmpty {
        Label("\(slow.count) getting slow", systemImage: "clock").scaledFont(.caption.weight(.medium)).foregroundStyle(Tone.warn.color)
          .padding(.horizontal, 6).padding(.vertical, 2).background(Tone.warn.soft, in: .rect(cornerRadius: 5))
          .help(slow.map { "\($0.key): \($0.value.message ?? "")" }.joined(separator: "\n"))
      }
    }
  }
}

// MARK: Shared bits

private struct Flag {
  let level: TicketAge.Level
  let message: String
}

/// Where a stuck ticket is flagged in Week and Month: only on the last day it shows up in the
/// range, so one ticket stuck for weeks doesn't paint every day it was touched.
@MainActor
private func flagsByDay(_ data: ActivityData, store: Store) -> [String: [String: Flag]] {
  var lastDay: [String: String] = [:]
  for day in data.days { for group in day.groups { if let key = group.ticket?.key { lastDay[key] = day.date } } }
  var flags: [String: [String: Flag]] = [:]
  for (key, date) in lastDay {
    guard let age = data.ticketAges[key], age.level != .ok, let message = age.message, store.activeParked(ticketRef(key)) == nil else { continue }
    flags[date, default: [:]][key] = Flag(level: age.level, message: message)
  }
  return flags
}

/// Flagged tickets first, worst first, so they survive a cell's "+N more".
private func flaggedFirst(_ groups: [DayGroup], _ flags: [String: Flag]?) -> [DayGroup] {
  func rank(_ group: DayGroup) -> Int {
    guard let key = group.ticket?.key, let flag = flags?[key] else { return 2 }
    return flag.level == .alert ? 0 : 1
  }
  return TodayRules.stableSorted(groups) { rank($0) < rank($1) }
}

private extension DayEntryKind {
  var symbol: String {
    switch self {
    case .pushed: "point.topleft.down.to.point.bottomright.curvepath"
    case .opened, .reopened: "arrow.triangle.pull"
    case .merged: "arrow.triangle.merge"
    case .closed, .changesRequested: "exclamationmark.circle"
    case .replied, .commented, .reviewed: "bubble.left"
    case .approved: "checkmark"
    case .ticket: "arrow.right"
    }
  }

  var color: AnyShapeStyle {
    switch self {
    case .opened, .reopened: AnyShapeStyle(Tone.info.color)
    case .merged, .approved: AnyShapeStyle(Tone.good.color)
    case .closed, .changesRequested: AnyShapeStyle(Tone.bad.color)
    case .ticket: AnyShapeStyle(.tertiary)
    default: AnyShapeStyle(.secondary)
    }
  }

  var label: String {
    switch self {
    case .pushed: "pushed"
    case .opened: "opened a PR"
    case .merged: "merged"
    case .closed: "closed a PR"
    case .reopened: "reopened a PR"
    case .replied: "replied to review comments"
    case .commented: "commented"
    case .approved: "approved"
    case .changesRequested: "requested changes"
    case .reviewed: "reviewed"
    case .ticket: "moved the ticket"
    }
  }
}

/// Which kinds of thing happened, as a row of small icons, outcomes first.
private struct KindIcons: View {
  let kinds: [DayEntryKind]
  private static let order: [DayEntryKind] = [.merged, .opened, .approved, .changesRequested, .reviewed, .pushed, .replied, .ticket]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Self.order.filter(kinds.contains), id: \.self) { kind in
        Image(systemName: kind.symbol).scaledFont(.system(size: 9)).foregroundStyle(kind.color).help(kind.label)
      }
    }
  }
}

/// One thing that happened, with its icon and a link when there is one.
private struct EntryView: View {
  let entry: DayEntry

  var body: some View {
    let label = HStack(spacing: 4) {
      Image(systemName: entry.kind.symbol).scaledFont(.caption2).foregroundStyle(entry.kind.color)
      Text(entry.text)
    }
    if let url = entry.url.flatMap(URL.init(string:)) {
      Link(destination: url) { label }.foregroundStyle(.secondary).clickable(underline: true)
    } else {
      label.foregroundStyle(.secondary)
    }
  }
}

private struct StateDot: View {
  let ticket: Ticket?
  var body: some View {
    Circle().fill(ticket.flatMap { Color(hex: $0.stateColor) } ?? Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
  }
}

// MARK: Month

/// A month at a glance: each day shows the tickets touched and what shipped, nothing more.
private struct MonthActivity: View {
  let data: ActivityData
  let openDay: (String) -> Void
  @Environment(Store.self) private var store
  private let shown = 3

  var body: some View {
    let flags = flagsByDay(data, store: store)
    let byDate = Dictionary(data.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    let today = TodayRules.localDate(Date(), data.range.timeZone)
    let month = data.range.start.prefix(7)
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) {
          Text($0).scaledFont(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
      }
      .background(Palette.fill.opacity(0.5))
      ForEach(ActivityDates.monthGrid(data.range.start, data.range.end), id: \.first) { week in
        Divider().overlay(Palette.border)
        HStack(spacing: 0) {
          ForEach(Array(week.enumerated()), id: \.element) { index, date in
            let inMonth = date.hasPrefix(month)
            let future = date > today
            cell(date, day: inMonth ? byDate[date] : nil, flags: flags[date], inMonth: inMonth, future: future, today: today)
              .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(Palette.border).frame(width: 1) } }
          }
        }
      }
    }
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    .clipShape(.rect(cornerRadius: 10))
  }

  private func cell(_ date: String, day: ActivityDay?, flags: [String: Flag]?, inMonth: Bool, future: Bool, today: String) -> some View {
    let entries = day?.groups.flatMap(\.entries) ?? []
    let merged = entries.filter { $0.kind == .merged }.count
    let opened = entries.filter { $0.kind == .opened }.count
    let reviews = day?.reviews.count ?? 0
    let content = VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(ActivityDates.format(date, "d"))
          .scaledFont(.caption.weight(date == today ? .semibold : .regular))
          .foregroundStyle(date == today ? AnyShapeStyle(Palette.primaryText) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
          .scaledFrame(width: 22, height: 22)
          .background(date == today ? Palette.primary : .clear, in: .circle)
        Spacer()
        HStack(spacing: 6) {
          if merged > 0 { Label("\(merged)", systemImage: "arrow.triangle.merge").foregroundStyle(Tone.good.color).help("\(merged) merged") }
          if opened > 0 { Label("\(opened)", systemImage: "arrow.triangle.pull").foregroundStyle(Tone.info.color).help("\(opened) opened") }
          if reviews > 0 { Label("\(reviews)", systemImage: "bubble.left").foregroundStyle(.secondary).help("\(reviews) reviewed") }
        }
        .labelStyle(CompactLabel())
        .scaledFont(.system(size: 10))
      }
      if let day {
        ForEach(flaggedFirst(day.groups, flags).prefix(shown)) { group in
          GroupPill(group: group, flag: group.ticket.flatMap { flags?[$0.key] })
        }
        if day.groups.count > shown { Text("+\(day.groups.count - shown) more").scaledFont(.caption2).foregroundStyle(.tertiary).padding(.leading, 4) }
      }
      Spacer(minLength: 0)
    }
    .padding(5)
    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
    .background(inMonth && !future ? .clear : Palette.fill.opacity(0.4))
    return Group {
      if inMonth && !future {
        Button { openDay(date) } label: { content.contentShape(.rect) }.buttonStyle(.plain).clickable()
      } else {
        content
      }
    }
  }
}

private struct CompactLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 2) {
      configuration.icon
      configuration.title
    }
  }
}

/// A ticket's key with its state colour, small enough for a calendar cell; tinted when stuck.
private struct GroupPill: View {
  let group: DayGroup
  let flag: Flag?

  var body: some View {
    let label = group.ticket?.key ?? (group.key.contains("#") ? "#\(group.key.components(separatedBy: "#").last ?? "")" : "branch")
    HStack(spacing: 4) {
      if let flag {
        Image(systemName: flag.level == .alert ? "exclamationmark.triangle" : "clock").scaledFont(.system(size: 9))
      } else {
        StateDot(ticket: group.ticket)
      }
      Text(label).scaledFont(.caption2.monospaced()).lineLimit(1)
      Spacer(minLength: 2)
      KindIcons(kinds: group.entries.map(\.kind))
    }
    .foregroundStyle(flag.map { $0.level == .alert ? AnyShapeStyle(Tone.bad.color) : AnyShapeStyle(Tone.warn.color) } ?? AnyShapeStyle(.primary))
    .padding(.horizontal, 4).padding(.vertical, 1)
    .background(flag.map { $0.level == .alert ? Tone.bad.soft : Tone.warn.soft } ?? .clear, in: .rect(cornerRadius: 4))
    .help(flag.map { "\(group.title)\n\($0.message)" } ?? group.title)
  }
}

// MARK: Week

/// Seven columns, one card per ticket a day; the day's heading opens its detail.
private struct WeekActivity: View {
  let data: ActivityData
  let openDay: (String) -> Void
  @Environment(Store.self) private var store
  private let shown = 6

  var body: some View {
    let flags = flagsByDay(data, store: store)
    let byDate = Dictionary(data.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    let today = TodayRules.localDate(Date(), data.range.timeZone)
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array((0 ..< 7).map { TodayRules.addDays(data.range.start, $0) }.enumerated()), id: \.element) { index, date in
        column(date, day: byDate[date], flags: flags[date], today: today)
          .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(Palette.border).frame(width: 1) } }
      }
    }
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    .clipShape(.rect(cornerRadius: 10))
  }

  private func column(_ date: String, day: ActivityDay?, flags: [String: Flag]?, today: String) -> some View {
    let future = date > today
    return VStack(alignment: .leading, spacing: 0) {
      Button { if !future { openDay(date) } } label: {
        HStack {
          Text("\(ActivityDates.format(date, "EEE")) \(ActivityDates.format(date, "d"))").fontWeight(date == today ? .semibold : .regular)
          Spacer()
          if let day { Text("\(day.groups.count)").foregroundStyle(.tertiary) }
        }
        .scaledFont(.caption)
        .foregroundStyle(future ? AnyShapeStyle(.tertiary) : date == today ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(date == today ? Palette.fill : .clear)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(future)
      .clickable()
      Divider().overlay(Palette.border)
      VStack(alignment: .leading, spacing: 6) {
        if let day {
          ForEach(flaggedFirst(day.groups, flags).prefix(shown)) { group in
            WeekCard(group: group, flag: group.ticket.flatMap { flags?[$0.key] }, age: group.ticket.flatMap { data.ticketAges[$0.key] }) { openDay(date) }
          }
          if day.groups.count > shown {
            Button("+\(day.groups.count - shown) more") { openDay(date) }.buttonStyle(.link).scaledFont(.caption2).clickable(underline: true)
          }
          if !day.reviews.isEmpty {
            Button { openDay(date) } label: {
              Label("\(day.reviews.count) review\(day.reviews.count == 1 ? "" : "s")", systemImage: "bubble.left")
                .scaledFont(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.fill.opacity(0.6), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain).clickable()
          }
        }
      }
      .padding(6)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
    .background(future ? Palette.fill.opacity(0.4) : .clear)
  }
}

private struct WeekCard: View {
  let group: DayGroup
  let flag: Flag?
  let age: TicketAge?
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          StateDot(ticket: group.ticket)
          Text(group.ticket?.key ?? "PR").scaledFont(.caption2.monospaced()).lineLimit(1)
          Spacer(minLength: 2)
          KindIcons(kinds: group.entries.map(\.kind))
        }
        Text(group.title).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
        if let flag, let age {
          Label("\(age.state) · \(age.workingDays)d", systemImage: flag.level == .alert ? "exclamationmark.triangle" : "clock")
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(flag.level == .alert ? Tone.bad.color : Tone.warn.color)
            .lineLimit(1)
            .help(flag.message)
        }
      }
      .padding(.horizontal, 7).padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(flag.map { $0.level == .alert ? Tone.bad.soft.opacity(0.5) : Tone.warn.soft.opacity(0.5) } ?? .clear, in: .rect(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(flag.map { ($0.level == .alert ? Tone.bad.color : Tone.warn.color).opacity(0.6) } ?? Palette.border))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .clickable()
  }
}

// MARK: Day

/// Everything about one day: a card per ticket, flagged ones first, then reviews.
private struct DayActivity: View {
  let data: ActivityData
  @Environment(Store.self) private var store
  @Environment(\.textScale) private var textScale
  @State private var width: CGFloat = 0

  var body: some View {
    let day = data.days.first
    let rank = { (group: DayGroup) -> Int in
      guard let key = group.ticket?.key else { return 2 }
      if store.activeParked(ticketRef(key)) != nil { return 3 }
      return switch data.ticketAges[key]?.level { case .alert: 0; case .warn: 1; default: 2 }
    }
    let groups = day.map { TodayRules.stableSorted($0.groups) { rank($0) < rank($1) } } ?? []
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(ActivityDates.format(data.range.start, "EEEEdMMMM")).scaledFont(.headline)
        Spacer()
        if let day, !day.detailed {
          Label("This far back GitHub no longer has pushes and replies; PRs, reviews and ticket moves are shown.", systemImage: "info.circle")
            .scaledFont(.caption).foregroundStyle(.tertiary)
        }
      }
      if day == nil {
        Text("Nothing recorded on this day.").foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity).padding(.vertical, 24)
          .background(Palette.card, in: .rect(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
      }
      let columns = width >= 760 * textScale ? 2 : 1
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 12) {
        ForEach(groups) { group in
          TicketCardView(group: group, prs: group.ticket.flatMap { data.ticketCards[$0.key] }, age: group.ticket.flatMap { data.ticketAges[$0.key] })
        }
      }
      if let day, !day.reviews.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Reviewed").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
          ForEach(day.reviews, id: \.pr.url) { review in
            HStack(spacing: 8) {
              EntryView(entry: review.entry)
              Text(review.pr.title).foregroundStyle(.secondary).lineLimit(1).help(review.pr.title)
              if let author = review.pr.author { AvatarView(url: author.avatarUrl, size: 16) }
            }
            .scaledFont(.caption)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }
}

/// One ticket's day: its status (flagged when it has sat too long), its PRs, and what happened.
private struct TicketCardView: View {
  let group: DayGroup
  let prs: [LinkedPr]?
  let age: TicketAge?
  @Environment(Store.self) private var store
  @Environment(Navigation.self) private var navigation

  var body: some View {
    let parked = group.ticket.flatMap { store.activeParked(ticketRef($0.key)) }
    let flagged = age.flatMap { $0.level != .ok && parked == nil ? $0 : nil }
    let flagColor = flagged.map { $0.level == .alert ? Tone.bad : Tone.warn }
    VStack(alignment: .leading, spacing: 0) {
      if let flagged, let message = flagged.message, let flagColor {
        Label(message, systemImage: flagged.level == .alert ? "exclamationmark.triangle" : "clock")
          .scaledFont(.caption.weight(.medium)).foregroundStyle(flagColor.color)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(flagColor.soft)
      }
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            if let ticket = group.ticket {
              TicketChip(ticket: ticket)
            } else {
              Text(group.key.contains("#") ? "PR" : "branch").scaledFont(.caption.monospaced()).foregroundStyle(.secondary).chipBorder()
            }
            if let parked { Chip(text: "Parked", tone: .info).help(parked.reason ?? "") }
            if let age, age.level == .ok || parked != nil {
              Text("\(age.state) for \(age.workingDays) working day\(age.workingDays == 1 ? "" : "s")").scaledFont(.caption2).foregroundStyle(.tertiary)
            }
          }
          HStack(alignment: .top, spacing: 4) {
            Group {
              if let url = group.ticket.flatMap({ URL(string: $0.url) }) {
                Link(group.title, destination: url).foregroundStyle(.primary).clickable(underline: true)
              } else {
                Text(group.title)
              }
            }
            .scaledFont(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(group.title)
            if let ticket = group.ticket {
              ItemControls(
                ref: ticketRef(ticket.key), title: "\(ticket.key) \(group.title)", url: ticket.url,
                prs: (prs ?? []).filter { $0.pr.state == .OPEN }.map { PrKey(repo: $0.pr.repo, number: $0.pr.number) }
              )
            }
          }
          if let ticket = group.ticket { NoteLine(ref: ticketRef(ticket.key)) }
        }
        if group.ticket != nil {
          VStack(alignment: .leading, spacing: 4) {
            Text("PULL REQUESTS").scaledFont(.caption2.weight(.medium)).foregroundStyle(.tertiary)
            if let prs, !prs.isEmpty {
              ForEach(prs, id: \.pr.url) { linked in linkedRow(linked) }
            } else {
              Text("No PR yet").scaledFont(.caption).foregroundStyle(.tertiary)
            }
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("ACTIVITY").scaledFont(.caption2.weight(.medium)).foregroundStyle(.tertiary)
          FlowLayout(spacing: 10) {
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in EntryView(entry: entry).scaledFont(.caption) }
          }
        }
      }
      .padding(12)
    }
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(flagColor.map { $0.color.opacity(0.6) } ?? Palette.border))
    .clipShape(.rect(cornerRadius: 10))
  }

  private func linkedRow(_ linked: LinkedPr) -> some View {
    let pr = linked.pr
    let (symbol, color, label): (String, AnyShapeStyle, String) =
      pr.state == .MERGED ? ("arrow.triangle.merge", AnyShapeStyle(Tone.good.color), "merged")
        : pr.state == .CLOSED ? ("xmark.circle", AnyShapeStyle(Tone.bad.color), "closed")
        : pr.isDraft ? ("circle.dashed", AnyShapeStyle(.secondary), "draft")
        : ("arrow.triangle.pull", AnyShapeStyle(Tone.info.color), "open")
    return HStack(spacing: 6) {
      Image(systemName: symbol).scaledFont(.caption).foregroundStyle(color).help(label)
      Button {
        navigation.open(PrKey(repo: pr.repo, number: pr.number))
      } label: {
        Text("\(Text("#\(String(pr.number))").foregroundStyle(.tertiary)) \(pr.title)").lineLimit(1)
      }
      .buttonStyle(.plain).clickable(underline: true).help(pr.title)
      Spacer(minLength: 4)
      if let status = linked.status { Chip(text: status.label, tone: status.tone) } else { Text(label).scaledFont(.caption2).foregroundStyle(.tertiary) }
      Link(destination: URL(string: pr.url)!) { Image(systemName: "arrow.up.right.square") }.foregroundStyle(.tertiary).help("Open on GitHub").clickable()
    }
    .scaledFont(.caption)
  }
}
