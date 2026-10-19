import SwiftUI

/// The home page: what needs you, what's new, and what to pick up next. src/routes/TodayPage.tsx
/// and components/today/sections.tsx in SwiftUI. Meetings arrive with the Calendar port.
struct TodayView: View {
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @State private var model = TodayModel()
  @Environment(\.textScale) private var textScale
  @State private var width: CGFloat = 0
  /// Before you've ever marked Today as seen, "new" means the last few days. Fixed per visit, so
  /// "New" doesn't shift under you between refreshes.
  @State private var firstVisitSince = Store.timestamp(Date(timeIntervalSinceNow: -3 * 86_400))

  var body: some View {
    // Derived once per render: the sections below all read it, and it filters every item.
    let data = self.data
    let since = self.since
    return PageScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        header(data, since: since)
        if let error = model.error {
          Label(error is NotConfigured ? "Setup needed: \(error.localizedDescription)" : error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Tone.bad.color)
        }
        ForEach(model.data?.warnings ?? [], id: \.self) { Text($0).scaledFont(.caption).foregroundStyle(Tone.warn.color) }
        if width >= 880 * textScale {
          HStack(alignment: .top, spacing: 20) {
            main(data, since: since).frame(maxWidth: .infinity, alignment: .leading)
            side(data, since: since).scaledFrame(width: 352)
          }
        } else {
          VStack(alignment: .leading, spacing: 20) {
            main(data, since: since)
            side(data, since: since)
          }
        }
      }
      .padding(.horizontal, 24).padding(.vertical, 20)
      .frame(maxWidth: 1120 * textScale, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .workbenchPage()
    .navigationTitle("Today")
    .navigationSubtitle(subtitle)
    .toolbar {
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load(settings: settings) } }
          .clickable()
          .keyboardShortcut("r")
          .disabled(model.loading)
      }
    }
    .task(id: model.data?.fetchedAt) {
      // Avatars ready before their rows scroll in, so none appears late.
      guard let raw = model.data else { return }
      let people = raw.needsYou.flatMap { ($0.nudge ?? []).joined().flatMap { [$0.owner] + $0.members.prefix(6) } }
      AvatarCache.shared.warm(
        people.compactMap { $0.avatarUrl.map { ($0, CGFloat(16)) } }
          + (raw.reviewRequests + raw.waiting).compactMap { $0.authorAvatarUrl.map { ($0, CGFloat(16)) } }
      )
    }
    .task {
      while !Task.isCancelled {
        await model.load(settings: settings)
        try? await Task.sleep(for: TodayModel.refreshInterval)
      }
    }
  }

  private var subtitle: String {
    if model.loading { return "Updating…" }
    return model.data.map { "Updated at \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" } ?? ""
  }

  /// Parked tickets and PRs leave everything that asks for attention; they're listed under Parked.
  /// A PR you've sent for review, or nudged within the nudge interval, waits on others instead.
  private var data: TodayData? {
    guard let raw = model.data else { return nil }
    let parkedTicket = { (key: String) in store.activeParked(ticketRef(key)) != nil }
    let active = raw.needsYou.filter { store.activeParked($0.ref) == nil && !($0.pr.map { store.parked(for: $0) != nil } ?? false) }
    let pinged = active.filter(isPinged)
    return TodayData(
      viewer: raw.viewer, timeZone: raw.timeZone, needsYou: active.filter { !isPinged($0) },
      upNext: raw.upNext.filter { !parkedTicket($0.ticket.key) }, tickets: raw.tickets, reviewRequests: raw.reviewRequests,
      inbox: raw.inbox, deadlines: raw.deadlines,
      waiting: pinged.compactMap(\.pr) + raw.waiting.filter { store.parked(for: $0) == nil },
      warnings: raw.warnings, fetchedAt: raw.fetchedAt
    )
  }

  private func isPinged(_ item: NeedsYouItem) -> Bool {
    guard let pr = item.pr else { return false }
    return TodayRules.recentlyPinged(store.pings[pr.url], kind: item.kind, nudgeAgainHours: settings.nudgeAgainHours)
  }

  private var since: String { store.setting(TodayModel.lastSeenKey) ?? firstVisitSince }

  private func header(_ data: TodayData?, since: String) -> some View {
    let hour = Calendar.current.component(.hour, from: Date())
    let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    var line = Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    if let data {
      let send = data.needsYou.filter { $0.kind == .sendForReview }.count
      let fix = data.needsYou.filter { $0.tone == .bad }.count
      let address = data.needsYou.filter { $0.tone == .warn }.count
      let ready = data.needsYou.filter { $0.tone == .good }.count
      let fresh = data.inbox.filter { $0.at > since }.count + data.reviewRequests.count
      let parts = [fix > 0 ? "\(fix) to fix" : nil, send > 0 ? "\(send) to send for review" : nil, address > 0 ? "\(address) to address" : nil, ready > 0 ? "\(ready) ready to merge" : nil, fresh > 0 ? "\(fresh) new" : nil]
        .compactMap { $0 }
      line += " · " + (parts.isEmpty ? "nothing urgent" : parts.joined(separator: " · "))
    }
    return VStack(alignment: .leading, spacing: 2) {
      Text(greeting).scaledFont(.title2.weight(.semibold))
      Text(line).foregroundStyle(.secondary)
    }
  }

  private func main(_ data: TodayData?, since: String) -> some View {
    LazyVStack(alignment: .leading, spacing: 20) {
      MeetingChangesSection()
      FocusSection(tickets: data?.tickets)
      if let data {
        NeedsYouSection(data: data)
        UpNextSection(data: data, since: since)
      } else if model.error == nil {
        // Where Needs you and Up next will be, so nothing moves when they arrive.
        LoadingPanel(text: "Gathering your day… the first load takes a few seconds.")
      }
    }
  }

  private func side(_ data: TodayData?, since: String) -> some View {
    LazyVStack(alignment: .leading, spacing: 20) {
      MeetingsTodaySection()
      if let data { NewForYouSection(data: data, since: since) }
      TodosSection(timeZone: data?.timeZone ?? settings.timeZone)
      ParkedSection()
      if let data {
        DeadlinesSection(data: data)
        WaitingSection(data: data)
      }
    }
  }
}

@MainActor
@Observable
final class TodayModel {
  static let refreshInterval: Duration = .seconds(60)
  /// The same setting the web version keeps, so marking seen in either counts for both.
  static let lastSeenKey = "today.lastSeenAt"

  private(set) var data: TodayData?
  private(set) var error: (any Error)?
  private(set) var loading = false

  func load(settings: AppSettings) async {
    loading = true
    defer { loading = false }
    do {
      data = try await TodayService.shared.build(config: PrConfig(settings), timeZone: settings.timeZone, newPrHours: settings.newPrHours)
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = error
    }
  }
}

// MARK: Shared bits

/// Shown in place of what's loading. The spinner gets a system colour: it can't draw the
/// palette's text style, and vanished in light mode.
struct LoadingPanel: View {
  let text: String

  var body: some View {
    VStack(spacing: 10) {
      ProgressView().scaledControlSize(.regular).tint(Color.secondary)
      Text(text).scaledFont(.callout).foregroundStyle(Color.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
  }
}

/// Opens an item's action: a PR's details here, anything else in the browser.
struct ActionButton: View {
  let label: String
  let action: ItemAction
  let tone: Tone
  @Environment(Navigation.self) private var navigation

  var body: some View {
    Button {
      switch action {
      case let .details(key):
        navigation.open(key)
      case let .web(url):
        NSWorkspace.shared.open(url)
      }
    } label: {
      HStack(spacing: 3) {
        Text(label)
        if case .web = action { Image(systemName: "arrow.up.right").scaledFont(.caption2) }
      }
    }
    .buttonStyle(.pill(tone))
    .clickable()
  }
}

/// A ticket's chip, or the PR's number when there's no ticket.
private struct TicketOrPr: View {
  let ticket: Ticket?
  let pr: Pr?

  var body: some View {
    if let ticket {
      TicketChip(ticket: ticket)
    } else if let pr {
      Text("#\(String(pr.number))").scaledFont(.caption.monospaced()).foregroundStyle(.secondary).chipBorder()
    }
  }
}

/// A PR in a short list: number and title opening its details, status on the right.
private struct PrLine<Accessory: View>: View {
  let pr: Pr
  @ViewBuilder let accessory: Accessory
  @Environment(Navigation.self) private var navigation

  var body: some View {
    HStack(spacing: 8) {
      Button {
        navigation.open(PrKey(pr))
      } label: {
        Text("\(Text("#\(String(pr.number))").foregroundStyle(.tertiary)) \(pr.title)").lineLimit(1).truncationMode(.tail)
      }
      .buttonStyle(.plain)
      .clickable(underline: true)
      .help(pr.title)
      Spacer(minLength: 4)
      accessory
      CopyLinkIcon(prs: [PrKey(pr)])
      Chip(text: pr.status.label, tone: pr.status.tone)
    }
    .scaledFont(.callout)
  }
}

/// The first few of a long list, then a link for the rest: a long list of heavy rows is what
/// made Today slow to scroll.
private struct Capped<Item: Identifiable, Row: View>: View {
  let items: [Item]
  let limit: Int
  @ViewBuilder let row: (_ index: Int, _ item: Item) -> Row
  @State private var showAll = false

  var body: some View {
    let shown = showAll ? items : Array(items.prefix(limit))
    ForEach(Array(shown.enumerated()), id: \.element.id) { row($0.offset, $0.element) }
    if items.count > limit {
      SmallLink(title: showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
    }
  }
}

private struct SmallLink: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(title, action: action).buttonStyle(.link).scaledFont(.caption).clickable(underline: true)
  }
}

// MARK: Needs you now

private struct ActionGroup: Identifiable {
  let id: String
  let title: String
  let kinds: [NeedsYouKind]
  let tone: Tone
}

/// Needs-you items grouped by what you'd do about them, most urgent first.
private let actionGroups = [
  ActionGroup(id: "resolve", title: "Resolve conflicts", kinds: [.conflicts], tone: .bad),
  ActionGroup(id: "ci", title: "Fix CI", kinds: [.ciFailing], tone: .bad),
  ActionGroup(id: "reply", title: "Reply", kinds: [.changesRequested, .threads], tone: .warn),
  ActionGroup(id: "send", title: "Send for review", kinds: [.sendForReview], tone: .info),
  ActionGroup(id: "nudge", title: "Nudge", kinds: [.stuckReview, .slowReview], tone: .warn),
  ActionGroup(id: "update", title: "Update branch", kinds: [.behind], tone: .warn),
  ActionGroup(id: "merge", title: "Merge", kinds: [.ready], tone: .good),
  ActionGroup(id: "housekeeping", title: "Housekeeping", kinds: [.mergedNotDone], tone: .neutral),
]

private struct NeedsYouSection: View {
  let data: TodayData
  /// Remembered like the web version's choice; a group that has emptied falls back to All.
  @AppStorage("needsYouFilter") private var filter = "all"
  @State private var showHousekeeping = false

  var body: some View {
    let groups = actionGroups.map { group in (group, data.needsYou.filter { group.kinds.contains($0.kind) }) }.filter { !$0.1.isEmpty }
    let active = groups.contains { $0.0.id == filter } ? filter : "all"
    let urgent = data.needsYou.filter { $0.kind != .mergedNotDone }.count
    Panel("Needs you now", aside: urgent > 0 ? "\(urgent) to act on" : "All clear") {
      if data.needsYou.isEmpty { Text("Nothing is waiting on you. Nice.").foregroundStyle(.tertiary) }
      if !groups.isEmpty {
        FlowLayout(spacing: 6) {
          FilterChip(title: "All", count: data.needsYou.count, tone: nil, isOn: active == "all") { filter = "all" }
          ForEach(groups, id: \.0.id) { group, items in
            FilterChip(title: group.title, count: items.count, tone: group.tone, isOn: active == group.id) { filter = group.id }
          }
        }
      }
      ForEach(groups.filter { active == "all" || $0.0.id == active }, id: \.0.id) { group, items in
        // Housekeeping waits behind a click in the overview; picked on its own, it shows.
        let hidden = group.id == "housekeeping" && active == "all" && !showHousekeeping
        LazyVStack(alignment: .leading, spacing: 0) {
          if active == "all" {
            HStack(spacing: 6) {
              RoundedRectangle(cornerRadius: 1).fill(group.tone.color).frame(width: 3, height: 12)
              Text(group.title).scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
              Text("\(items.count)").scaledFont(.caption).foregroundStyle(.tertiary)
              if group.id == "housekeeping" { SmallLink(title: hidden ? "Show" : "Hide") { showHousekeeping.toggle() } }
            }
            .padding(.top, 6)
          }
          if !hidden {
            Capped(items: items, limit: 5) { index, item in
              if index > 0 { Divider().overlay(Palette.border) }
              NeedsYouRow(item: item)
            }
          }
        }
      }
    }
  }
}

private struct FilterChip: View {
  let title: String
  let count: Int
  let tone: Tone?
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let tone { Circle().fill(tone.color).frame(width: 6, height: 6) }
        Text(title).fontWeight(isOn ? .medium : .regular)
        Text("\(count)").foregroundStyle(.tertiary)
      }
      .scaledFont(.caption)
      .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 9).padding(.vertical, 3)
      .background(isOn ? Palette.fill : .clear, in: .capsule)
      .overlay(Capsule().strokeBorder(isOn ? AnyShapeStyle(.primary.opacity(0.4)) : AnyShapeStyle(Palette.border)))
    }
    .buttonStyle(.plain)
    .clickable()
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

private struct NeedsYouRow: View {
  let item: NeedsYouItem
  @Environment(Navigation.self) private var navigation
  @Environment(Store.self) private var store

  /// Sending for review and nudging are pings: done once you've told people, then left alone.
  private var ping: Ping.Kind? {
    switch item.kind {
    case .sendForReview: .sent
    case .stuckReview, .slowReview: .nudged
    default: nil
    }
  }

  var body: some View {
    let title = item.ticket?.title ?? item.pr?.title ?? ""
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          TicketOrPr(ticket: item.ticket, pr: item.pr)
          if let pr = item.pr {
            Button { navigation.open(PrKey(pr)) } label: { Text(title).scaledFont(.callout.weight(.medium)).lineLimit(1) }
              .buttonStyle(.plain).clickable(underline: true).help(title)
          } else {
            Text(title).scaledFont(.callout.weight(.medium)).lineLimit(1).help(title)
          }
        }
        Text("\(Text(item.title).foregroundStyle(.primary).fontWeight(.medium))\(item.pr.map { Text(" · #\(String($0.number))").foregroundStyle(.tertiary) } ?? Text(""))\(item.detail.map { Text(" · \($0)") } ?? Text(""))")
          .scaledFont(.caption).foregroundStyle(.secondary)
        NoteLine(ref: item.ref)
        if let nudge = item.nudge, !nudge.isEmpty { NudgeList(groups: nudge) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // One glass pass for the row's pills, not one each: they redraw as the page scrolls.
      GlassEffectContainer(spacing: 4) {
        HStack(spacing: 4) {
          if let ping, let pr = item.pr {
            CopyLinkButton(url: pr.url)
            Button(ping == .sent ? "Sent" : "Nudged", systemImage: "checkmark") { store.ping(pr.url, ping) }
              .buttonStyle(.pill(item.tone)).clickable()
              .help(ping == .sent ? "Mark as sent to the team for review" : "Mark the reviewers as nudged")
          } else {
            ActionButton(label: item.actionLabel, action: item.action, tone: item.tone)
          }
          ItemControls(
            ref: item.ref, title: title, url: item.ticket?.url ?? item.pr?.url, prs: item.pr.map { [PrKey($0)] } ?? [], copyLink: ping == nil
          )
        }
      }
    }
    .padding(.vertical, 8)
  }
}

/// Whose approval a slow review waits on: each team with its members, ready to ping.
private struct NudgeList: View {
  let groups: [[NudgeTarget]]
  private let membersShown = 6

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("WAITING ON").scaledFont(.caption2.weight(.medium)).foregroundStyle(.tertiary)
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(group.enumerated()), id: \.element.owner.id) { index, target in
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 5) {
                if index > 0 { Text("or").foregroundStyle(.tertiary) }
                AvatarView(url: target.owner.avatarUrl, size: 16, team: target.owner.kind == .team)
                Link(target.owner.name, destination: URL(string: target.owner.url)!).fontWeight(.medium).foregroundStyle(.primary)
                  .clickable(underline: true)
                if target.owner.kind == .team { Text("\(target.members.count) people").foregroundStyle(.tertiary) }
              }
              if !target.members.isEmpty {
                FlowLayout(spacing: 10) {
                  ForEach(target.members.prefix(membersShown), id: \.id) { member in
                    Link(destination: URL(string: member.url)!) {
                      HStack(spacing: 4) {
                        AvatarView(url: member.avatarUrl, size: 16)
                        Text(member.name)
                      }
                    }
                    .foregroundStyle(.secondary)
                    .clickable(underline: true)
                    .help(member.id)
                  }
                  if target.members.count > membersShown {
                    Text("+\(target.members.count - membersShown) more").foregroundStyle(.tertiary)
                      .help(target.members.dropFirst(membersShown).map(\.name).joined(separator: "\n"))
                  }
                }
                .padding(.leading, 21)
              }
            }
          }
        }
      }
    }
    .scaledFont(.caption)
    .padding(.horizontal, 10).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.fill.opacity(0.6), in: .rect(cornerRadius: 6))
  }
}

// MARK: Up next

private struct UpNextSection: View {
  let data: TodayData
  let since: String
  @State private var showAll = false
  private let shown = 6

  var body: some View {
    Panel("Up next", aside: "ranked by priority, deadlines and blockers") {
      if data.upNext.isEmpty { Text("No unstarted tickets assigned to you.").foregroundStyle(.tertiary) }
      let items = showAll ? data.upNext : Array(data.upNext.prefix(shown))
      ForEach(Array(items.enumerated()), id: \.element.ticket.key) { index, item in
        if index > 0 { Divider().overlay(Palette.border) }
        UpNextRow(item: item, isNew: (item.ticket.assignedAt ?? "") > since)
      }
      if data.upNext.count > shown {
        SmallLink(title: showAll ? "Show fewer" : "Show all \(data.upNext.count)") { showAll.toggle() }
      }
    }
  }
}

private struct UpNextRow: View {
  let item: UpNextItem
  let isNew: Bool

  var body: some View {
    let ticket = item.ticket.ticket
    HStack(alignment: .top, spacing: 10) {
      Group {
        switch item.ticket.priority {
        case 1: Image(systemName: "flame.fill").foregroundStyle(Tone.bad.color).help("Urgent")
        case 2: Image(systemName: "exclamationmark.circle").foregroundStyle(Tone.warn.color).help("High priority")
        default: Color.clear
        }
      }
      .scaledFont(.caption)
      .frame(width: 14)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          TicketChip(ticket: ticket)
          Link(ticket.title, destination: URL(string: ticket.url)!).foregroundStyle(.primary).lineLimit(1)
            .clickable(underline: true).help(ticket.title)
          if isNew { Chip(text: "New", tone: .info) }
        }
        if !item.reasons.isEmpty {
          FlowLayout(spacing: 4) {
            ForEach(item.reasons, id: \.self) { reason in
              Chip(text: reason, tone: reason.range(of: "overdue|Release Blocker|Urgent", options: .regularExpression) != nil ? .bad : .neutral)
            }
          }
        }
        NoteLine(ref: ticketRef(ticket.key))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ItemControls(ref: ticketRef(ticket.key), title: "\(ticket.key) \(ticket.title)", url: ticket.url)
    }
    .scaledFont(.callout)
    .padding(.vertical, 8)
  }
}

// MARK: New for you

/// What happened since you last looked: your Linear inbox and reviews asked of you on GitHub.
/// Assignments the inbox lacks (archived there) still show, from the tickets themselves.
private struct NewForYouSection: View {
  let data: TodayData
  let since: String
  @Environment(Store.self) private var store
  @State private var showEarlier = false

  var body: some View {
    let inboxAssigned = Set(data.inbox.filter { $0.kind == .assigned }.compactMap { $0.ticket?.key })
    let fromTickets = data.tickets
      .filter { ($0.assignedAt ?? "") > since && !inboxAssigned.contains($0.key) }
      .map { ticket in
        InboxItem(
          id: "assigned:\(ticket.key)", kind: .assigned, at: ticket.assignedAt!, unread: false, actor: nil, verb: "assigned you",
          ticket: .init(key: ticket.key, title: ticket.ticket.title, url: ticket.ticket.url, state: ticket.ticket.state, stateColor: ticket.ticket.stateColor),
          project: nil, snippet: nil, url: ticket.ticket.url
        )
      }
    let feed = TodayRules.stableSorted(data.inbox + fromTickets) { $0.at > $1.at }
    let fresh = feed.filter { $0.at > since }
    let earlier = feed.filter { $0.at <= since }
    let nothing = fresh.isEmpty && data.reviewRequests.isEmpty
    let lastSeen = store.setting(TodayModel.lastSeenKey)

    Panel("New for you") {
      HStack(spacing: 8) {
        if !fresh.isEmpty { Text("\(fresh.count) since \(lastSeen.map(relative) ?? "3 days")").foregroundStyle(.secondary) }
        if !nothing {
          SmallLink(title: "Mark seen") { store.setSetting(TodayModel.lastSeenKey, Store.timestamp(Date())) }
        }
      }
    } content: {
      if nothing { Text("Nothing new since you last looked.").foregroundStyle(.tertiary) }
      if !fresh.isEmpty {
        Text("In Linear").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
        Capped(items: fresh, limit: 8) { _, item in InboxRow(item: item) }
      }
      if !data.reviewRequests.isEmpty {
        Text("Asked to review").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
        Capped(items: data.reviewRequests, limit: 6) { _, pr in
          PrLine(pr: pr) { AvatarView(url: pr.authorAvatarUrl, size: 16) }
        }
      }
      if !earlier.isEmpty {
        SmallLink(title: showEarlier ? "Hide earlier" : "Earlier (\(earlier.count))") { showEarlier.toggle() }
        if showEarlier {
          Capped(items: earlier, limit: 8) { _, item in InboxRow(item: item).opacity(0.8) }
        }
      }
    }
  }
}

/// One thing from your Linear inbox. The whole row opens it in Linear: hovering highlights the
/// row and underlines the ticket, since a link inside a sentence gives no pointer on its own.
private struct InboxRow: View {
  let item: InboxItem
  @State private var hovering = false

  /// The ticket key or project name, linked to where it happened.
  private var subject: AttributedString {
    var text = AttributedString(item.ticket?.key ?? item.project?.name ?? "")
    if hovering { text.underlineStyle = .single }
    return text
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .frame(width: 16)
        .overlay(alignment: .topTrailing) {
          if item.unread { Circle().fill(Tone.info.color).frame(width: 6, height: 6).offset(x: 3, y: -2).help("Unread in Linear") }
        }
      VStack(alignment: .leading, spacing: 2) {
        // One sentence that wraps as a whole, with the ticket or project as an inline link.
        Text("\(Text(item.actor?.name ?? "Linear").fontWeight(.medium)) \(Text(item.verb).foregroundStyle(.secondary)) \(Text(subject).fontWeight(.medium))")
          .tint(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let title = item.ticket?.title { Text(title).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1).help(title) }
        if let snippet = item.snippet { Text("“\(snippet)”").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(2) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(relative(item.at)).scaledFont(.caption).foregroundStyle(.tertiary)
    }
    .scaledFont(.callout)
    .padding(.horizontal, 6).padding(.vertical, 4)
    .background(hovering ? Palette.fill : .clear, in: .rect(cornerRadius: 6))
    .padding(.horizontal, -6).padding(.vertical, -4)
    .contentShape(.rect)
    .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
    .onHover { hovering = $0 && url != nil }
    .pointerStyle(url != nil ? .link : nil)
    .animation(.easeOut(duration: 0.12), value: hovering)
    .help(url != nil ? "Open in Linear" : "")
  }

  private var url: URL? { item.url.flatMap(URL.init(string:)) }

  private var symbol: String {
    switch item.kind {
    case .assigned: "person.badge.plus"
    case .comment: "bubble.left"
    case .mention: "at"
    case .status: "arrow.right"
    case .priority: "flame"
    case .project: "folder"
    case .other: "bell"
    }
  }

  private var color: Color {
    switch item.kind {
    case .assigned: Tone.info.color
    case .mention: Tone.warn.color
    case .priority: Tone.bad.color
    default: .secondary
    }
  }
}

// MARK: Focus

private struct FocusSection: View {
  let tickets: [OpenTicket]?
  @Environment(Store.self) private var store

  var body: some View {
    let open = Dictionary((tickets ?? []).map { (ticketRef($0.key), $0) }, uniquingKeysWith: { first, _ in first })
    if store.pins.isEmpty {
      Text("Pin what you want to focus on today with the pin icon on any item.")
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
    } else {
      Panel("Focus", aside: "\(store.pins.count) pinned") {
        ForEach(store.pins, id: \.ref) { pin in
          let ticket = open[pin.ref]
          let finished = pin.ref.hasPrefix("ticket:") && tickets != nil && ticket == nil
          HStack(spacing: 8) {
            if let ticket {
              TicketChip(ticket: ticket.ticket)
            } else {
              Text(pin.ref.replacingOccurrences(of: #"^\w+:"#, with: "", options: .regularExpression))
                .scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Group {
              if let url = pin.url.flatMap(URL.init(string:)) {
                Link(ticket?.ticket.title ?? pin.title, destination: url).foregroundStyle(.primary).clickable(underline: true)
              } else {
                Text(ticket?.ticket.title ?? pin.title)
              }
            }
            .lineLimit(1)
            .strikethrough(finished)
            .opacity(finished ? 0.6 : 1)
            if finished { Text("done").scaledFont(.caption).foregroundStyle(Tone.good.color) }
            Spacer(minLength: 4)
            ItemControls(ref: pin.ref, title: pin.title, url: pin.url)
            if finished { SmallLink(title: "Clear") { store.unpin(pin.ref) } }
          }
          .scaledFont(.callout)
        }
      }
    }
  }
}

// MARK: Todos

private struct TodosSection: View {
  let timeZone: String
  @Environment(Store.self) private var store
  @State private var text = ""
  @State private var due: Date?
  /// macOS focuses the first text field in a window, which would scroll Today down to this one.
  @FocusState private var editing: Bool

  var body: some View {
    let open = store.todos.filter { $0.doneAt == nil }
    let today = TodayRules.localDate(Date(), timeZone)
    Panel("Todos", aside: "\(open.count) open") {
      HStack(spacing: 6) {
        HStack(spacing: 6) {
          TextField("Add a todo…", text: $text)
            .textFieldStyle(.plain)
            .focused($editing)
            .onSubmit(add)
            .task { editing = false }
          if let due {
            HStack(spacing: 3) {
              Text(due.formatted(.dateTime.day().month(.abbreviated)))
              Button("Clear Due Date", systemImage: "xmark.circle.fill") { self.due = nil }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tertiary).clickable()
            }
            .scaledFont(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Palette.fill, in: .capsule)
          }
          DueDateButton(due: $due)
        }
        .scaledFont(.callout)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Palette.background, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(editing ? Color.workbenchAccent : Palette.border, lineWidth: editing ? 1.5 : 1))
        Button("Add Todo", systemImage: "plus", action: add)
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          .scaledControlSize(.regular)
          .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
          .clickable()
          .help("Add todo")
      }
      Text("Mention a ticket key, like MX-2481, to link the todo to it.").scaledFont(.caption).foregroundStyle(.tertiary)
      if open.isEmpty { Text("Nothing on your list.").foregroundStyle(.tertiary) }
      ForEach(store.todos) { todo in
        TodoRow(todo: todo, today: today)
      }
    }
  }

  private func add() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // "MX-2481 check the copy" links the todo to that ticket.
    let key = trimmed.firstMatch(of: /\b[A-Z][A-Z0-9]{1,9}-\d{1,7}\b/).map { String($0.output) }
    store.addTodo(trimmed, ref: key.map(ticketRef), dueDate: due.map { TodayRules.localDate($0, TimeZone.current.identifier) })
    text = ""
    due = nil
  }
}

/// Opens a calendar to pick the day a todo is due. Todos keep a day, not a time, the same as in the
/// web version, which reads the same database.
private struct DueDateButton: View {
  @Binding var due: Date?
  @State private var open = false
  @State private var picked = Date()

  var body: some View {
    Button("Due Date", systemImage: "calendar") {
      picked = due ?? Date()
      open = true
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.plain)
    .foregroundStyle(due == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.workbenchAccent))
    .clickable()
    .help("Pick a due date")
    .popover(isPresented: $open, arrowEdge: .bottom) {
      VStack(alignment: .trailing, spacing: 8) {
        DatePicker("Due", selection: $picked, displayedComponents: .date)
          .datePickerStyle(.graphical)
          .labelsHidden()
        HStack {
          if due != nil {
            Button("No Due Date") {
              due = nil
              open = false
            }
            .clickable()
          }
          Spacer()
          Button("Set") {
            due = picked
            open = false
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .clickable()
        }
        .scaledControlSize(.small)
      }
      .padding(12)
    }
  }
}

private struct TodoRow: View {
  let todo: Todo
  let today: String
  @Environment(Store.self) private var store
  @State private var hovering = false

  var body: some View {
    let done = todo.doneAt != nil
    let overdue = !done && (todo.dueDate.map { $0 < today } ?? false)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Toggle(isOn: Binding(get: { done }, set: { store.setTodo(todo.id, done: $0) })) {
        Text(todo.text).strikethrough(done).foregroundStyle(done ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
      }
      .toggleStyle(.checkbox)
      Spacer(minLength: 4)
      if let date = todo.dueDate {
        Text(date == today ? "today" : TodayRules.parseInstant("\(date)T12:00:00Z").map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? date)
          .scaledFont(.caption).foregroundStyle(overdue ? AnyShapeStyle(Tone.bad.color) : AnyShapeStyle(.tertiary))
      }
      Button("Delete Todo", systemImage: "trash") { store.removeTodo(todo.id) }
        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.tertiary)
        .opacity(hovering ? 1 : 0).clickable()
    }
    .scaledFont(.callout)
    .onHover { hovering = $0 }
    .contextMenu { Button("Delete", role: .destructive) { store.removeTodo(todo.id) } }
  }
}

// MARK: Parked, deadlines, waiting

/// What you've set aside, collapsed by default; each can be unparked or comes back on its date.
private struct ParkedSection: View {
  @Environment(Store.self) private var store
  @State private var open = false

  var body: some View {
    let items = store.activeParkedItems
    if !items.isEmpty {
      Panel("Parked") {
        HStack(spacing: 8) {
          Text("\(items.count) set aside").foregroundStyle(.secondary)
          SmallLink(title: open ? "Hide" : "Show") { open.toggle() }
        }
      } content: {
        if !open {
          Text("Kept out of Needs you, Up next and the stuck flags.").scaledFont(.caption).foregroundStyle(.tertiary)
        } else {
          ForEach(items, id: \.ref) { item in
            HStack(alignment: .top, spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(item.ref.replacingOccurrences(of: #"^\w+:"#, with: "", options: .regularExpression))
                    .scaledFont(.caption.monospaced()).foregroundStyle(.secondary)
                  let title = item.title.replacingOccurrences(of: #"^[A-Z][A-Z0-9]+-\d+\s+"#, with: "", options: .regularExpression)
                  if let url = item.url.flatMap(URL.init(string:)) {
                    Link(title, destination: url).foregroundStyle(.primary).lineLimit(1).clickable(underline: true)
                  } else {
                    Text(title).lineLimit(1)
                  }
                }
                let back = item.until.flatMap { TodayRules.parseInstant("\($0)T12:00:00Z") }.map { "back \($0.formatted(.dateTime.day().month(.abbreviated)))" }
                Text([item.reason, back, "parked \(relative(item.parkedAt))"].compactMap { $0 }.joined(separator: " · "))
                  .scaledFont(.caption).foregroundStyle(.tertiary)
              }
              Spacer(minLength: 4)
              SmallLink(title: "Unpark") { store.unpark(item.ref) }
            }
            .scaledFont(.callout)
          }
        }
      }
    }
  }
}

private struct DeadlinesSection: View {
  let data: TodayData

  var body: some View {
    Panel("Deadlines") {
      if data.deadlines.isEmpty { Text("No cycle or project deadlines coming up.").foregroundStyle(.tertiary) }
      ForEach(data.deadlines, id: \.name) { deadline in
        let overdue = deadline.daysLeft < 0
        let soon = !overdue && deadline.daysLeft <= 3
        let color: AnyShapeStyle = overdue ? AnyShapeStyle(Tone.bad.color) : soon ? AnyShapeStyle(Tone.warn.color) : AnyShapeStyle(.tertiary)
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "calendar.badge.clock").foregroundStyle(color)
          VStack(alignment: .leading, spacing: 2) {
            if let url = deadline.url.flatMap(URL.init(string:)) {
              Link(deadline.name, destination: url).foregroundStyle(.primary).lineLimit(1).clickable(underline: true)
            } else {
              Text(deadline.name).lineLimit(1)
            }
            Text("\(deadline.ticketCount) of your ticket\(deadline.ticketCount == 1 ? "" : "s")").scaledFont(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          Text(overdue ? "\(-deadline.daysLeft)d overdue" : deadline.daysLeft == 0 ? "today" : "in \(deadline.daysLeft)d")
            .scaledFont(.caption.weight(.medium))
            .foregroundStyle(overdue || soon ? color : AnyShapeStyle(.secondary))
        }
        .scaledFont(.callout)
      }
    }
  }
}

private struct WaitingSection: View {
  let data: TodayData
  @Environment(Store.self) private var store

  var body: some View {
    Panel("Waiting on others", aside: "\(data.waiting.count) PRs") {
      if data.waiting.isEmpty { Text("Nothing of yours is waiting on others.").foregroundStyle(.tertiary) }
      Capped(items: data.waiting, limit: 6) { _, pr in
        PrLine(pr: pr) { PingLabel(ping: store.pings[pr.url]) }
      }
    }
  }
}

/// "sent 2 hours ago" / "nudged yesterday" beside a waiting PR, or a clock when neither happened.
struct PingLabel: View {
  let ping: Ping?

  var body: some View {
    if let ping, let last = ping.last {
      let nudged = ping.nudgedAt.flatMap(TodayRules.parseInstant).map { $0 >= last } ?? false
      Text("\(nudged ? "nudged" : "sent") \(last, format: .relative(presentation: .named))").scaledFont(.caption).foregroundStyle(.tertiary)
    } else {
      Image(systemName: "clock").scaledFont(.caption).foregroundStyle(.tertiary)
    }
  }
}
