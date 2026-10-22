import SwiftUI

// Meeting pieces shared by Today and the Calendar page: src/components/calendar/MeetingBits.tsx and
// today/meetings.tsx in SwiftUI.

/// A meeting's time in the home zone and in this Mac's zone; when the two read the same, it says so.
struct BothZones: View {
  let start: String
  let end: String
  let allDay: Bool
  let homeZone: String
  var withDay = false

  init(_ meeting: Meeting, homeZone: String, withDay: Bool = false) {
    (start, end, allDay, self.homeZone, self.withDay) = (meeting.start, meeting.end, meeting.allDay, homeZone, withDay)
  }

  var body: some View {
    let localZone = TimeZone.current.identifier
    let home = CalendarTime.timeRange(start: start, end: end, allDay: allDay, zone: homeZone, withDay: withDay)
    if allDay {
      Text(home)
    } else {
      let local = CalendarTime.timeRange(start: start, end: end, allDay: allDay, zone: localZone, withDay: withDay)
      if local == home {
        Text("\(home) \(Text(CalendarTime.city(homeZone) + (localZone == homeZone ? "" : " · same for you")).foregroundStyle(.tertiary))")
      } else {
        Text("\(home) \(Text(CalendarTime.city(homeZone)).foregroundStyle(.tertiary))\(Text(" · ").foregroundStyle(.tertiary))\(local) \(Text("your time (\(CalendarTime.city(localZone)))").foregroundStyle(.tertiary))")
      }
    }
  }
}

struct JoinButton: View {
  let meeting: Meeting

  var body: some View {
    if let join = meeting.joinUrl.flatMap(URL.init(string:)), !(meeting.change?.isDeleted ?? false) {
      Link(destination: join) { Label("Join", systemImage: "video.fill") }
        .buttonStyle(.pill(.neutral, prominent: true))
        .clickable()
    }
  }
}

struct MeetingTitle: View {
  let meeting: Meeting

  var body: some View {
    let deleted = meeting.change?.isDeleted ?? false
    let faded = deleted || meeting.declined
    Group {
      if let url = meeting.htmlUrl.flatMap(URL.init(string:)), !deleted {
        Link(meeting.title, destination: url).clickable(underline: true)
      } else {
        Text(meeting.title)
      }
    }
    .foregroundStyle(faded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    .strikethrough(deleted)
    .lineLimit(1)
    .help(meeting.title)
  }
}

/// A rescheduled or deleted meeting: what it is now, what it was, and a way to dismiss the notice.
struct MeetingChangeRow: View {
  let meeting: Meeting
  let homeZone: String
  @Environment(CalendarModel.self) private var calendar
  @Environment(Store.self) private var store

  var body: some View {
    if let change = meeting.change {
      let deleted = change.isDeleted
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: deleted ? "calendar.badge.minus" : "clock.arrow.circlepath")
          .foregroundStyle(deleted ? Tone.bad.color : Tone.warn.color)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            MeetingTitle(meeting: meeting).fontWeight(.medium)
            Chip(text: deleted ? "Deleted" : "Rescheduled", tone: deleted ? .bad : .warn)
          }
          if case let .rescheduled(previousStart, previousEnd, at) = change {
            Text("\(Text("Now ").foregroundStyle(.secondary))\(BothZonesText(meeting: meeting, homeZone: homeZone))").scaledFont(.caption)
            Text("Was \(Text(CalendarTime.timeRange(start: previousStart, end: previousEnd, allDay: meeting.allDay, zone: homeZone, withDay: true)).strikethrough()) · moved \(relative(at))")
              .scaledFont(.caption).foregroundStyle(.secondary)
          } else {
            Text("Was \(BothZonesText(meeting: meeting, homeZone: homeZone)) · removed \(relative(change.at))").scaledFont(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        JoinButton(meeting: meeting)
        Button("Dismiss", systemImage: "xmark") { calendar.dismiss(meeting, store) }
          .labelStyle(.iconOnly).buttonStyle(.borderless).clickable()
          .help(deleted ? "Dismiss and forget this meeting" : "Dismiss: the new time is noted")
      }
      .scaledFont(.callout)
      .padding(.vertical, 6)
    }
  }
}

/// BothZones as text, for putting inside a sentence.
private func BothZonesText(meeting: Meeting, homeZone: String) -> Text {
  let localZone = TimeZone.current.identifier
  let home = CalendarTime.timeRange(start: meeting.start, end: meeting.end, allDay: meeting.allDay, zone: homeZone, withDay: true)
  if meeting.allDay { return Text(home) }
  let local = CalendarTime.timeRange(start: meeting.start, end: meeting.end, allDay: false, zone: localZone, withDay: true)
  if local == home { return Text("\(home) \(Text(CalendarTime.city(homeZone)).foregroundStyle(.tertiary))") }
  return Text("\(home) \(Text(CalendarTime.city(homeZone)).foregroundStyle(.tertiary)) · \(local) \(Text("your time").foregroundStyle(.tertiary))")
}

/// Rescheduled and deleted meetings, whatever day they're on, until you dismiss them.
struct MeetingChangesSection: View {
  @Environment(CalendarModel.self) private var calendar
  @Environment(Store.self) private var store
  @Environment(AppSettings.self) private var settings

  var body: some View {
    let changes = calendar.changes(store)
    if !changes.isEmpty {
      Panel("Meeting changes", aside: "\(changes.count) changed") {
        ForEach(Array(changes.enumerated()), id: \.element.id) { index, meeting in
          if index > 0 { Divider().overlay(Palette.border) }
          MeetingChangeRow(meeting: meeting, homeZone: settings.timeZone)
        }
      }
    }
  }
}

struct MeetingsTodaySection: View {
  @Environment(CalendarModel.self) private var calendar
  @Environment(Store.self) private var store
  @Environment(AppSettings.self) private var settings

  var body: some View {
    let connection = calendar.connection(settings, store)
    if connection != .connected {
      Panel("Meetings today") {
        HStack(spacing: 4) {
          SettingsLink { Text("Connect Google Calendar") }.buttonStyle(.link).clickable(underline: true)
          Text("to see your meetings here.").foregroundStyle(.secondary)
        }
        .scaledFont(.callout)
      }
    } else {
      let meetings = calendar.today(settings, store)
      Panel("Meetings today", aside: calendar.lastSync == nil ? "" : meetings.isEmpty ? "None" : "\(meetings.count)") {
        if let error = calendar.lastSync?.error { Text("Google sync failed: \(error)").scaledFont(.caption).foregroundStyle(Tone.warn.color) }
        if calendar.lastSync == nil {
          Text("Checking your calendar…").foregroundStyle(.secondary)
        } else if meetings.isEmpty {
          Text("No meetings today.").foregroundStyle(.secondary)
        }
        TimelineView(.periodic(from: .now, by: 60)) { context in
          let now = Store.timestamp(context.date)
          // Once today has nothing left, the next meeting on a later day.
          let next = calendar.next(after: context.date, store).flatMap { next in meetings.contains { $0.id == next.id } ? nil : next }
          VStack(alignment: .leading, spacing: 10) {
            ForEach(meetings) { meeting in
              let over = !meeting.allDay && meeting.end <= now
              let live = !meeting.allDay && meeting.start <= now && now < meeting.end
              HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(live ? Tone.good.color : Color.warshaAccent.opacity(0.4)).frame(width: 2, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    MeetingTitle(meeting: meeting).fontWeight(.medium)
                    if live { Chip(text: "Now", tone: .good) }
                    if case .rescheduled = meeting.change { Chip(text: "Moved", tone: .warn) }
                    if meeting.declined { Text("Declined").scaledFont(.caption2).foregroundStyle(.tertiary) }
                  }
                  BothZones(meeting, homeZone: settings.timeZone).scaledFont(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !over { JoinButton(meeting: meeting) }
              }
              .scaledFont(.callout)
              .opacity(over ? 0.55 : 1)
            }
            if let next {
              if !meetings.isEmpty { Divider().overlay(Palette.border) }
              Text("NEXT MEETING").scaledFont(.caption2.weight(.medium)).foregroundStyle(.tertiary)
              HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.warshaAccent.opacity(0.4)).frame(width: 2, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    MeetingTitle(meeting: next).fontWeight(.medium)
                    if case .rescheduled = next.change { Chip(text: "Moved", tone: .warn) }
                  }
                  BothZones(next, homeZone: settings.timeZone, withDay: true).scaledFont(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                JoinButton(meeting: next)
              }
              .scaledFont(.callout)
            }
          }
        }
      }
    }
  }
}

/// What a meeting is, when (both zones), and what changed.
struct MeetingDetails: View {
  let meeting: Meeting
  let homeZone: String
  @Environment(CalendarModel.self) private var calendar
  @Environment(Store.self) private var store
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(meeting.title).scaledFont(.headline).strikethrough(meeting.change?.isDeleted ?? false).fixedSize(horizontal: false, vertical: true)
      BothZones(meeting, homeZone: homeZone, withDay: true).scaledFont(.caption).foregroundStyle(.secondary)
      if let location = meeting.location, !location.hasPrefix("http") {
        Label(location, systemImage: "mappin.and.ellipse").scaledFont(.caption).foregroundStyle(.secondary)
      }
      switch meeting.change {
      case let .rescheduled(previousStart, previousEnd, _):
        Label("Rescheduled from \(CalendarTime.timeRange(start: previousStart, end: previousEnd, allDay: meeting.allDay, zone: homeZone, withDay: true))", systemImage: "clock.arrow.circlepath")
          .scaledFont(.caption).foregroundStyle(Tone.warn.color)
          .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Tone.warn.soft, in: .rect(cornerRadius: 6))
      case .deleted:
        Label("Deleted from your calendar", systemImage: "calendar.badge.minus")
          .scaledFont(.caption).foregroundStyle(Tone.bad.color)
          .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Tone.bad.soft, in: .rect(cornerRadius: 6))
      case nil: EmptyView()
      }
      if meeting.declined { Text("You declined this one.").scaledFont(.caption).foregroundStyle(.secondary) }
      HStack(spacing: 10) {
        JoinButton(meeting: meeting)
        if let url = meeting.htmlUrl.flatMap(URL.init(string:)), !(meeting.change?.isDeleted ?? false) {
          Link(destination: url) { Label("Open in Google Calendar", systemImage: "arrow.up.right") }
            .scaledFont(.caption).foregroundStyle(.secondary).clickable(underline: true)
        }
        Spacer()
        if meeting.change != nil {
          Button("Dismiss") {
            calendar.dismiss(meeting, store)
            dismiss()
          }
          .scaledControlSize(.small)
          .clickable()
        }
      }
    }
    .padding(12)
    .scaledFrame(width: 320, alignment: .leading)
  }
}
