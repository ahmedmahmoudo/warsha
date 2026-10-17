import SwiftUI

/// Your Google Calendar as Day, Week or Month, in your home zone or this Mac's, with rescheduled
/// and deleted meetings marked. src/routes/CalendarPage.tsx and components/calendar/grid.tsx.
struct CalendarView: View {
  enum Span: String, CaseIterable, Identifiable {
    case day, week, month
    var id: Self { self }
    var label: String { rawValue.capitalized }
  }

  enum ZoneChoice: String {
    case home, local
  }

  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(CalendarModel.self) private var calendar
  @AppStorage("calendarSpan") private var span: Span = .week
  @AppStorage("calendarZone") private var zoneChoice: ZoneChoice = .home
  @State private var date: String?
  @State private var meetings: [Meeting] = []
  @State private var error: String?
  @State private var loading = false

  private var zone: String { zoneChoice == .local ? TimeZone.current.identifier : settings.timeZone }
  private var today: String { TodayRules.localDate(Date(), zone) }
  private var current: String { date ?? today }

  var body: some View {
    let range = Self.range(span, current)
    VStack(alignment: .leading, spacing: 12) {
      controls(range)
      if calendar.connection(settings, store) != .connected {
        HStack(spacing: 4) {
          SettingsLink { Text("Connect Google Calendar") }.buttonStyle(.link).clickable(underline: true)
          Text("to see your meetings here.").foregroundStyle(.secondary)
        }
      }
      if let error { Text("Google: \(error)").font(.caption).foregroundStyle(Tone.warn.color) }
      Group {
        if span == .month {
          MonthGrid(first: range.first, last: range.last, meetings: meetings, zone: zone, homeZone: settings.timeZone, today: today) { day in
            span = .day
            date = day
          }
        } else {
          TimeGrid(days: range.days, meetings: meetings, zone: zone, homeZone: settings.timeZone, today: today)
        }
      }
      .opacity(loading && meetings.isEmpty ? 0.5 : 1)
    }
    .padding(.horizontal, 20).padding(.vertical, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .workbenchPage()
    .navigationTitle("Calendar")
    .navigationSubtitle(loading ? "Updating…" : calendar.email(store) ?? "")
    .toolbar {
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(force: true) } }
          .keyboardShortcut("r")
          .disabled(loading)
          .help("Check Google for changes now")
      }
    }
    .task(id: "\(span.rawValue)|\(current)|\(zone)|\(calendar.connection(settings, store))") {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  private func controls(_ range: (days: [String], first: String, last: String)) -> some View {
    HStack(spacing: 12) {
      Picker("View", selection: $span) {
        ForEach(Span.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .focusEffectDisabled()
      HStack(spacing: 4) {
        Button("Earlier", systemImage: "chevron.left") { date = Self.step(span, current, -1) }
          .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().keyboardShortcut(.leftArrow, modifiers: .command)
        Text(Self.label(span, range.first, range.last)).font(.headline).monospacedDigit().frame(minWidth: 170)
        Button("Later", systemImage: "chevron.right") { date = Self.step(span, current, 1) }
          .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().keyboardShortcut(.rightArrow, modifiers: .command)
        if current != today {
          Button("Today") { date = nil }.controlSize(.small).clickable().keyboardShortcut("t", modifiers: .command)
        }
      }
      Spacer()
      Picker("Time zone", selection: $zoneChoice) {
        Text(CalendarTime.city(settings.timeZone)).tag(ZoneChoice.home)
        Text(TimeZone.current.identifier == settings.timeZone ? "Local" : "Local · \(CalendarTime.city(TimeZone.current.identifier))").tag(ZoneChoice.local)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .focusEffectDisabled()
    }
  }

  private func load(force: Bool = false) async {
    guard calendar.connection(settings, store) == .connected else {
      meetings = []
      return
    }
    let range = Self.range(span, current)
    // A day either side covers every zone's idea of where the shown days begin and end.
    let from = TodayRules.parseInstant("\(TodayRules.addDays(range.days.first!, -1))T00:00:00Z")!
    let to = TodayRules.parseInstant("\(TodayRules.addDays(range.days.last!, 2))T00:00:00Z")!
    loading = true
    defer { loading = false }
    do {
      meetings = try await calendar.range(from: from, to: to, settings: settings, store: store, force: force)
      error = calendar.lastSync?.error
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: Dates

  private static func monday(_ date: String) -> String {
    let weekday = CalendarTime.calendar("UTC").component(.weekday, from: TodayRules.parseInstant("\(date)T12:00:00Z")!)
    return TodayRules.addDays(date, -((weekday + 5) % 7))
  }

  private static func addMonths(_ date: String, _ months: Int) -> String {
    let calendar = CalendarTime.calendar("UTC")
    let moved = calendar.date(byAdding: .month, value: months, to: TodayRules.parseInstant("\(date.prefix(7))-01T12:00:00Z")!)!
    return TodayRules.localDate(moved, "UTC")
  }

  /// The days a view shows around `date`, and the month bounds for the month view.
  static func range(_ span: Span, _ date: String) -> (days: [String], first: String, last: String) {
    switch span {
    case .day: return ([date], date, date)
    case .week:
      let start = monday(date)
      let days = (0 ..< 7).map { TodayRules.addDays(start, $0) }
      return (days, start, days[6])
    case .month:
      let first = "\(date.prefix(7))-01"
      let last = TodayRules.addDays(addMonths(first, 1), -1)
      let gridStart = monday(first)
      let gridEnd = TodayRules.addDays(monday(last), 6)
      let count = TodayRules.daysBetween(gridStart, gridEnd) + 1
      return ((0 ..< count).map { TodayRules.addDays(gridStart, $0) }, first, last)
    }
  }

  private static func step(_ span: Span, _ date: String, _ by: Int) -> String {
    switch span {
    case .day: TodayRules.addDays(date, by)
    case .week: TodayRules.addDays(date, by * 7)
    case .month: addMonths(date, by)
    }
  }

  private static func format(_ date: String, _ pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_AU")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = pattern
    return formatter.string(from: TodayRules.parseInstant("\(date)T12:00:00Z")!)
  }

  private static func label(_ span: Span, _ first: String, _ last: String) -> String {
    switch span {
    case .day: format(first, "EEE d MMM yyyy")
    case .week: first.prefix(7) == last.prefix(7) ? "\(format(first, "d")) – \(format(last, "d MMM yyyy"))" : "\(format(first, "d MMM")) – \(format(last, "d MMM yyyy"))"
    case .month: format(first, "MMMM yyyy")
    }
  }

  static func weekday(_ date: String) -> String { format(date, "EEE") }
  static func dayOfMonth(_ date: String) -> String { format(date, "d") }
}

// MARK: Grids

private func blockStyle(_ meeting: Meeting, ghost: Bool) -> (fill: Color, edge: Color, dashed: Bool, text: AnyShapeStyle) {
  if ghost { return (.clear, Tone.warn.color.opacity(0.6), true, AnyShapeStyle(Tone.warn.color.opacity(0.8))) }
  if meeting.change?.isDeleted ?? false { return (Tone.bad.soft.opacity(0.5), Tone.bad.color.opacity(0.5), true, AnyShapeStyle(.secondary)) }
  if meeting.declined { return (.clear, Color.workbenchAccent.opacity(0.3), false, AnyShapeStyle(.secondary)) }
  if case .rescheduled = meeting.change { return (Tone.warn.soft, Tone.warn.color, false, AnyShapeStyle(.primary)) }
  return (Color.workbenchAccent.opacity(0.15), Color.workbenchAccent, false, AnyShapeStyle(.primary))
}

/// A meeting chip or block that opens its details.
private struct MeetingButton<Label: View>: View {
  let meeting: Meeting
  let homeZone: String
  @ViewBuilder let label: Label
  @State private var open = false

  var body: some View {
    Button { open = true } label: { label }
      .buttonStyle(.plain)
      .clickable()
      .popover(isPresented: $open, arrowEdge: .trailing) { MeetingDetails(meeting: meeting, homeZone: homeZone) }
  }
}

/// Days side by side with an hour scale, all-day meetings in a strip on top.
private struct TimeGrid: View {
  let days: [String]
  let meetings: [Meeting]
  let zone: String
  let homeZone: String
  let today: String
  private let hour: CGFloat = 48
  private let gutter: CGFloat = 52

  /// A meeting's block on one day, or a dashed ghost where a rescheduled one used to be.
  struct Block: Identifiable {
    let meeting: Meeting
    let startMin: Int
    let endMin: Int
    let ghost: Bool
    var column = 0
    var columns = 1
    var id: String { meeting.id + (ghost ? ":was" : "") }
  }

  var body: some View {
    let allDay = meetings.filter(\.allDay)
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        // A fixed-size spacer: a bare Color would stretch to every bit of height it's offered.
        Spacer().frame(width: gutter, height: 1)
        ForEach(days, id: \.self) { day in
          VStack(spacing: 2) {
            Text(CalendarView.weekday(day)).font(.caption).foregroundStyle(.secondary)
            Text(CalendarView.dayOfMonth(day))
              .font(.title3.weight(day == today ? .semibold : .regular))
              .foregroundStyle(day == today ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
              .frame(width: 30, height: 30)
              .background(day == today ? Color.workbenchAccent : .clear, in: .circle)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
          .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
        }
      }
      Divider().overlay(Palette.border)
      if !allDay.isEmpty {
        HStack(alignment: .top, spacing: 0) {
          Text("all day").font(.caption2).foregroundStyle(.tertiary).frame(width: gutter - 6, alignment: .trailing).padding(.trailing, 6).padding(.top, 4)
          ForEach(days, id: \.self) { day in
            VStack(spacing: 2) {
              ForEach(allDay.filter { CalendarTime.onDay($0, day, zone: zone) }) { meeting in
                let style = blockStyle(meeting, ghost: false)
                MeetingButton(meeting: meeting, homeZone: homeZone) {
                  Text(meeting.title).font(.caption).lineLimit(1).foregroundStyle(style.text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(style.fill, in: .rect(cornerRadius: 4))
                }
              }
            }
            .padding(2)
            .frame(maxWidth: .infinity, alignment: .top)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
          }
        }
        Divider().overlay(Palette.border)
      }
      ScrollViewReader { proxy in
        ScrollView {
          HStack(alignment: .top, spacing: 0) {
            // Real rows, one an hour, so scrolling to an hour finds it (offsets don't move a view's frame).
            VStack(spacing: 0) {
              ForEach(0 ..< 24, id: \.self) { hour in
                Text(hour == 0 ? "" : hourLabel(hour)).font(.caption2).foregroundStyle(.tertiary)
                  .padding(.trailing, 6)
                  .offset(y: -7)
                  .frame(width: gutter, height: self.hour, alignment: .topTrailing)
                  .id(hour)
              }
            }
            ForEach(days, id: \.self) { day in
              dayColumn(day)
            }
          }
        }
        .task { proxy.scrollTo(7, anchor: .top) }
      }
    }
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    .clipShape(.rect(cornerRadius: 10))
  }

  private func hourLabel(_ hour: Int) -> String {
    hour == 12 ? "12 pm" : hour < 12 ? "\(hour) am" : "\(hour - 12) pm"
  }

  private func dayColumn(_ day: String) -> some View {
    let blocks = layout(meetings.filter { !$0.allDay }.flatMap { meeting -> [Block] in
      var found: [Block] = []
      if let own = block(meeting, meeting.start, meeting.end, day, ghost: false) { found.append(own) }
      if case let .rescheduled(previousStart, previousEnd, _) = meeting.change,
         let was = block(meeting, previousStart, previousEnd, day, ghost: true) { found.append(was) }
      return found
    })
    return GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        ForEach(1 ..< 24, id: \.self) { hour in
          Rectangle().fill(Palette.border.opacity(0.6)).frame(height: 1).offset(y: CGFloat(hour) * self.hour)
        }
        ForEach(blocks) { block in
          let width = geometry.size.width / CGFloat(block.columns)
          let height = max(CGFloat(block.endMin - block.startMin) / 60 * hour - 2, 20)
          let style = blockStyle(block.meeting, ghost: block.ghost)
          MeetingButton(meeting: block.meeting, homeZone: homeZone) {
            VStack(alignment: .leading, spacing: 1) {
              Text((block.ghost ? "Moved: " : "") + block.meeting.title).font(.caption.weight(.medium)).lineLimit(height < 36 ? 1 : 3)
              if height >= 36 {
                Text(block.ghost ? "was here" : CalendarTime.clock(block.meeting.start, zone)).font(.caption2).opacity(0.8)
              }
            }
            .strikethrough(block.meeting.change?.isDeleted ?? false)
            .foregroundStyle(style.text)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .frame(width: width - 3, height: height, alignment: .topLeading)
            .background(style.fill, in: .rect(cornerRadius: 6))
            .overlay(alignment: .leading) {
              if !style.dashed { Rectangle().fill(style.edge).frame(width: 3) }
            }
            .overlay {
              if style.dashed || block.meeting.declined {
                RoundedRectangle(cornerRadius: 6).strokeBorder(style.edge, style: StrokeStyle(lineWidth: 1, dash: style.dashed ? [4, 3] : []))
              }
            }
            .clipShape(.rect(cornerRadius: 6))
          }
          .help(block.ghost ? "\(block.meeting.title) (moved from here)" : block.meeting.title)
          .offset(x: CGFloat(block.column) * width + 1, y: CGFloat(block.startMin) / 60 * hour)
        }
        TimelineView(.periodic(from: .now, by: 60)) { context in
          let now = CalendarTime.zoned(Store.timestamp(context.date), zone)
          if now.date == day {
            HStack(spacing: 0) {
              Circle().fill(Tone.bad.color).frame(width: 8, height: 8).offset(x: -4)
              Rectangle().fill(Tone.bad.color).frame(height: 1)
            }
            .offset(y: CGFloat(now.minutes) / 60 * hour - 4)
            .allowsHitTesting(false)
          }
        }
      }
    }
    .frame(height: hour * 24)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
  }

  private func block(_ meeting: Meeting, _ start: String, _ end: String, _ day: String, ghost: Bool) -> Block? {
    let from = CalendarTime.zoned(start, zone)
    let to = CalendarTime.zoned(end, zone)
    if from.date > day || to.date < day || (to.date == day && to.minutes == 0 && from.date < day) { return nil }
    let startMin = from.date < day ? 0 : from.minutes
    let endMin = to.date > day ? 24 * 60 : to.minutes
    return Block(meeting: meeting, startMin: startMin, endMin: max(endMin, startMin + 15), ghost: ghost)
  }

  /// Overlapping blocks share the width side by side, the way Google lays them out.
  private func layout(_ blocks: [Block]) -> [Block] {
    let sorted = blocks.sorted { $0.startMin != $1.startMin ? $0.startMin < $1.startMin : $0.endMin > $1.endMin }
    var placed: [Block] = []
    var cluster: [Int] = []
    var columnEnds: [Int] = []
    var clusterEnd = -1
    func close() {
      for index in cluster { placed[index].columns = columnEnds.count }
      cluster = []
      columnEnds = []
    }
    for var block in sorted {
      if block.startMin >= clusterEnd { close() }
      var column = columnEnds.firstIndex { $0 <= block.startMin } ?? -1
      if column == -1 {
        columnEnds.append(0)
        column = columnEnds.count - 1
      }
      columnEnds[column] = block.endMin
      block.column = column
      placed.append(block)
      cluster.append(placed.count - 1)
      clusterEnd = max(clusterEnd, block.endMin)
    }
    close()
    return placed
  }
}

/// Weeks of days, each with its first few meetings as chips.
private struct MonthGrid: View {
  let first: String
  let last: String
  let meetings: [Meeting]
  let zone: String
  let homeZone: String
  let today: String
  let openDay: (String) -> Void
  private let chips = 3

  var body: some View {
    let days = CalendarView.range(.month, first).days
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0 ..< min($0 + 7, days.count)]) }
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(weeks[0], id: \.self) { day in
          Text(CalendarView.weekday(day)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
      }
      .background(Palette.fill.opacity(0.5))
      ForEach(weeks, id: \.first) { week in
        Divider().overlay(Palette.border)
        HStack(spacing: 0) {
          ForEach(Array(week.enumerated()), id: \.element) { index, day in
            dayCell(day).overlay(alignment: .leading) { if index > 0 { Rectangle().fill(Palette.border).frame(width: 1) } }
          }
        }
      }
    }
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    .clipShape(.rect(cornerRadius: 10))
  }

  private func dayCell(_ day: String) -> some View {
    let inMonth = day >= first && day <= last
    let onDay = meetings.filter { CalendarTime.onDay($0, day, zone: zone) }
    return VStack(alignment: .leading, spacing: 2) {
      Button { openDay(day) } label: {
        Text(CalendarView.dayOfMonth(day))
          .font(.caption.weight(day == today ? .semibold : .regular))
          .foregroundStyle(day == today ? AnyShapeStyle(Color.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
          .frame(width: 22, height: 22)
          .background(day == today ? Color.workbenchAccent : .clear, in: .circle)
      }
      .buttonStyle(.plain)
      .clickable()
      .frame(maxWidth: .infinity)
      ForEach(onDay.prefix(chips)) { meeting in
        let style = blockStyle(meeting, ghost: false)
        MeetingButton(meeting: meeting, homeZone: homeZone) {
          HStack(spacing: 4) {
            if !meeting.allDay { Text(CalendarTime.clock(meeting.start, zone)).opacity(0.7) }
            Text(meeting.title).lineLimit(1)
          }
          .font(.caption2)
          .strikethrough(meeting.change?.isDeleted ?? false)
          .foregroundStyle(style.text)
          .padding(.horizontal, 4).padding(.vertical, 2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(style.fill, in: .rect(cornerRadius: 4))
        }
      }
      if onDay.count > chips {
        Button("\(onDay.count - chips) more") { openDay(day) }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary).clickable(underline: true)
      }
      Spacer(minLength: 0)
    }
    .padding(4)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .top)
    .background(inMonth ? .clear : Palette.fill.opacity(0.4))
  }
}
