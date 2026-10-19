import Foundation

/// Builds Today: server/today/build.ts (with the ticket ages from activity/cards.ts) in Swift. The
/// rules match the web version's; its README describes them.
actor TodayService {
  static let shared = TodayService()

  /// The oldest PR list Today will build from.
  private static let prListMaxAge: TimeInterval = 15
  /// Teams change rarely; their members are re-read hourly.
  private static let teamMaxAge: TimeInterval = 60 * 60

  private var teams: [String: (at: Date, members: [Person])] = [:]

  /// `newPrHours` is how long a PR counts as new, to send for review rather than nudge; 0 turns it off.
  func build(config: PrConfig, timeZone: String, newPrHours: Int = 24) async throws -> TodayData {
    var warnings: [String] = []
    // Today is only as fresh as the PR lists it's built from, so it takes them recent too.
    async let mineLoad = PrService.shared.load(.mine, config: config, maxAge: Self.prListMaxAge)
    async let reviewingLoad = Result { try await PrService.shared.load(.reviewing, config: config, maxAge: Self.prListMaxAge) }
    async let ticketsLoad = Result { try await Linear.myOpenTickets(apiKey: config.linearApiKey) }
    async let notificationsLoad = Result { try await Linear.myNotifications(apiKey: config.linearApiKey) }
    let mine = try await mineLoad

    let reviewing: PrsResponse?
    switch await reviewingLoad {
    case let .success(value): reviewing = value
    case let .failure(error):
      warnings.append("Review requests: \(error.localizedDescription)")
      reviewing = nil
    }
    var tickets: [OpenTicket]
    switch await ticketsLoad {
    case let .success(value): tickets = value
    case let .failure(error):
      warnings.append("Linear: \(error.localizedDescription)")
      tickets = []
    }
    let notifications: [RawNotification]
    switch await notificationsLoad {
    case let .success(value): notifications = value
    case let .failure(error):
      if !(error is NotConfigured) { warnings.append("Linear inbox: \(error.localizedDescription)") }
      notifications = []
    }

    // A ticket created already assigned to you has no assignment in its history; the inbox's
    // "assigned you" has the time, and failing that it was yours from creation.
    var assignedByInbox: [String: String] = [:]
    for raw in notifications where raw.type == "issueAssignedToYou" {
      if let issue = raw.issue, raw.createdAt > (assignedByInbox[issue.identifier] ?? "") { assignedByInbox[issue.identifier] = raw.createdAt }
    }
    for index in tickets.indices where tickets[index].assignedAt == nil {
      tickets[index].assignedAt = assignedByInbox[tickets[index].key] ?? tickets[index].createdAt
    }
    warnings += mine.warnings.filter { !$0.hasPrefix("Linear: Add a Linear API key") }

    let now = Date()
    let today = TodayRules.localDate(now, timeZone)
    let openPrs = mine.open.filter { !$0.isDraft }

    // How long each PR's ticket has sat in review, for the stuck and slow flags.
    var prTickets: [Ticket] = []
    for ticket in openPrs.flatMap(\.tickets) where !prTickets.contains(where: { $0.key == ticket.key }) { prTickets.append(ticket) }
    let ages = await ticketAges(prTickets, timeZone: timeZone, apiKey: config.linearApiKey, warnings: &warnings)

    var needsYou: [NeedsYouItem] = []
    var waiting: [Pr] = []
    for pr in openPrs {
      let ticket = pr.tickets.first
      let age = ticket.flatMap { ages[$0.key] }
      let ageMessage = age.flatMap { $0.level != .ok && $0.message != nil ? ($0.level, $0.message!) : nil }
      var need = TodayRules.prNeed(pr, ageMessage: ageMessage)
      // A new PR nobody has looked at yet goes to the team first; nudging comes later.
      if need == nil || need?.kind == .stuckReview || need?.kind == .slowReview,
         let fresh = TodayRules.sendForReview(pr, now: now, newPrHours: newPrHours) {
        need = fresh
      }
      guard let need else {
        waiting.append(pr)
        continue
      }
      var item = NeedsYouItem(
        id: "\(need.kind.rawValue):\(pr.repo)#\(pr.number)", kind: need.kind, tone: need.tone, title: need.title, detail: need.detail,
        ticket: ticket, pr: pr, actionLabel: need.actionLabel, action: need.action,
        ref: ticket.map { ticketRef($0.key) } ?? prRef(pr.repo, pr.number)
      )
      if need.kind == .stuckReview || need.kind == .slowReview || need.kind == .sendForReview {
        item.nudge = await nudgeTargets(pr, viewer: mine.viewer, token: config.githubToken, warnings: &warnings)
      }
      needsYou.append(item)
    }

    // Merged in GitHub, still open in Linear: worth closing so the board tells the truth.
    for ticket in tickets where ticket.ticket.state.range(of: "merged", options: .caseInsensitive) != nil {
      needsYou.append(NeedsYouItem(
        id: "merged-not-done:\(ticket.key)", kind: .mergedNotDone, tone: .neutral, title: "Still \"\(ticket.ticket.state)\" in Linear",
        detail: "The PR is merged; move the ticket on once it ships", ticket: ticket.ticket, pr: nil, actionLabel: "Open ticket",
        action: .web(URL(string: ticket.ticket.url)!), ref: ticketRef(ticket.key)
      ))
    }
    needsYou = TodayRules.stableSorted(needsYou) { a, b in
      let (left, right) = (NeedsYouKind.allCases.firstIndex(of: a.kind)!, NeedsYouKind.allCases.firstIndex(of: b.kind)!)
      if left != right { return left < right }
      return (a.pr?.updatedAt ?? "") > (b.pr?.updatedAt ?? "")
    }

    // Reviews asked of you personally; reviews you've already given don't count.
    let viewer = mine.viewer.lowercased()
    let reviewRequests = (reviewing?.open ?? []).filter { pr in
      ((pr.reviewGate?.codeOwners.flatMap { $0 } ?? []) + (pr.reviewGate?.optional ?? []))
        .contains { $0.kind == .user && $0.id.lowercased() == viewer }
    }

    return TodayData(
      viewer: mine.viewer, timeZone: timeZone, needsYou: needsYou,
      upNext: TodayRules.rankUpNext(tickets, today: today, timeZone: timeZone, now: now), tickets: tickets,
      reviewRequests: reviewRequests, inbox: TodayRules.inbox(notifications, now: now),
      deadlines: TodayRules.deadlines(tickets, today: today, timeZone: timeZone), waiting: waiting, warnings: warnings, fetchedAt: now
    )
  }

  private static let stateSinceChunk = 25

  /// Status age for each in-flight ticket, looked up a chunk of keys at a time.
  private func ticketAges(_ tickets: [Ticket], timeZone: String, apiKey: String, warnings: inout [String]) async -> [String: TicketAge] {
    // Only tickets that can age need their history.
    let aging = tickets.filter { $0.stateType == "started" && $0.state.range(of: "merged", options: .caseInsensitive) == nil }
    let keys = aging.map(\.key)
    var since: [String: String] = [:]
    do {
      for start in stride(from: 0, to: keys.count, by: Self.stateSinceChunk) {
        let chunk = Array(keys[start ..< min(start + Self.stateSinceChunk, keys.count)])
        since.merge(try await Linear.stateSince(chunk, apiKey: apiKey)) { $1 }
      }
    } catch {
      if !(error is NotConfigured) { warnings.append("Linear status history: \(error.localizedDescription)") }
      return [:]
    }
    var ages: [String: TicketAge] = [:]
    for ticket in aging {
      if let age = TodayRules.ticketAge(ticket, since: since[ticket.key], timeZone: timeZone) { ages[ticket.key] = age }
    }
    return ages
  }

  /// Who a slow review waits on: its code owners (or, without code-owner rules, the reviewers asked),
  /// each team with its members. You and the PR's author are left out: nudging yourself helps no one.
  private func nudgeTargets(_ pr: Pr, viewer: String, token: String, warnings: inout [String]) async -> [[NudgeTarget]] {
    let gate = pr.reviewGate
    let groups: [[Person]] = !(gate?.codeOwners.isEmpty ?? true) ? gate!.codeOwners : !(gate?.optional.isEmpty ?? true) ? [gate!.optional] : []
    let skip: Set = [viewer.lowercased(), pr.author.lowercased()]
    var result: [[NudgeTarget]] = []
    for group in groups {
      var targets: [NudgeTarget] = []
      for owner in group where !skip.contains(owner.id.lowercased()) {
        guard owner.kind == .team else {
          targets.append(NudgeTarget(owner: owner, members: []))
          continue
        }
        do {
          let members = try await members(of: owner.id, token: token)
          targets.append(NudgeTarget(owner: owner, members: members.filter { !skip.contains($0.id.lowercased()) }))
        } catch {
          warnings.append("Couldn't list \(owner.name)'s members: \(error.localizedDescription)")
          targets.append(NudgeTarget(owner: owner, members: []))
        }
      }
      if !targets.isEmpty { result.append(targets) }
    }
    return result
  }

  private func members(of team: String, token: String) async throws -> [Person] {
    if let cached = teams[team], -cached.at.timeIntervalSinceNow < Self.teamMaxAge { return cached.members }
    let parts = team.split(separator: "/", maxSplits: 1).map(String.init)
    let members = try await GitHub.teamMembers(org: parts[0], slug: parts[1], token: token)
    teams[team] = (Date(), members)
    return members
  }
}

/// Today's rules, apart from the loading so they can be tested.
enum TodayRules {
  /// How "Up next" weighs a ticket. Each part also becomes a reason shown beside it.
  private static let priorityPoints: [Int: (Int, String?)] = [1: (40, "Urgent"), 2: (30, "High priority"), 3: (20, nil), 4: (10, nil), 0: (5, nil)]
  private static let releaseBlockerPoints = 40
  private static let newAssignmentDays = 2.0
  private static let newAssignmentPoints = 10
  private static let readyToStartPoints = 5
  /// Deadlines worth showing: cycles ending within two weeks, project targets within a month.
  private static let cycleHorizonDays = 14
  private static let projectHorizonDays = 30
  /// A target date this far past is a stale plan, not a deadline; it stops counting.
  private static let projectOverdueLimitDays = 30
  private static let finishedProject: Set = ["completed", "canceled"]
  /// Not started yet, so a candidate for what to pick up next.
  private static let notStarted: Set = ["unstarted", "backlog", "triage"]

  /// A calendar date (YYYY-MM-DD) in the zone, like the web's localDate.
  static func localDate(_ instant: Date, _ timeZone: String) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
    let parts = calendar.dateComponents([.year, .month, .day], from: instant)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  static func localDate(_ iso: String, _ timeZone: String) -> String {
    localDate(parseInstant(iso) ?? Date(), timeZone)
  }

  /// GitHub's and Linear's timestamps, with or without fractional seconds.
  static func parseInstant(_ iso: String) -> Date? {
    (try? Date(iso, strategy: .iso8601)) ?? (try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
  }

  private static func noon(_ date: String) -> Date? { parseInstant("\(date)T12:00:00Z") }

  static func daysBetween(_ from: String, _ to: String) -> Int {
    guard let a = noon(from), let b = noon(to) else { return 0 }
    return Int((b.timeIntervalSince(a) / 86_400).rounded())
  }

  static func addDays(_ date: String, _ days: Int) -> String {
    guard let start = noon(date) else { return date }
    return localDate(start.addingTimeInterval(Double(days) * 86_400), "UTC")
  }

  private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(abs(count) == 1 ? "" : "s")" }

  private static func due(_ days: Int, _ what: String) -> String {
    if days < 0 { return "\(what) \(plural(-days, "day")) overdue" }
    if days == 0 { return "\(what) due today" }
    return "\(what) due in \(plural(days, "day"))"
  }

  /// Swift's sort isn't stable; JavaScript's is, and ties keep their order there.
  static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { a, b in
      if less(a.element, b.element) { return true }
      if less(b.element, a.element) { return false }
      return a.offset < b.offset
    }.map(\.element)
  }

  /// The project's target date if it's a live deadline: project still active and not long past.
  static func liveTarget(_ project: OpenTicket.ProjectInfo?, today: String) -> (date: String, days: Int)? {
    guard let project, let target = project.targetDate, !finishedProject.contains(project.statusType ?? "") else { return nil }
    let days = daysBetween(today, target)
    return days < -projectOverdueLimitDays ? nil : (target, days)
  }

  static func rankUpNext(_ tickets: [OpenTicket], today: String, timeZone: String, now: Date) -> [UpNextItem] {
    let ranked = tickets
      .filter { notStarted.contains($0.ticket.stateType) && $0.ticket.state.range(of: "duplicate", options: .caseInsensitive) == nil }
      .map { ticket -> UpNextItem in
        var reasons: [String] = []
        let (points, reason) = priorityPoints[ticket.priority] ?? (0, nil)
        var score = points
        if let reason { reasons.append(reason) }
        if ticket.labels.contains(where: { $0.range(of: "release blocker", options: .caseInsensitive) != nil }) {
          score += releaseBlockerPoints
          reasons.append("Release Blocker")
        }
        if let target = liveTarget(ticket.projectInfo, today: today) {
          let days = target.days
          let points = days < 0 ? 25 : days <= 7 ? 20 : days <= 14 ? 10 : 0
          if points > 0 {
            score += points
            reasons.append(due(days, "Project"))
          }
        }
        if let cycle = ticket.cycle {
          let days = daysBetween(today, localDate(cycle.endsAt, timeZone))
          let points = days <= 3 ? 20 : days <= 7 ? 12 : days <= 14 ? 5 : 0
          if points > 0 {
            score += points
            reasons.append(days <= 0 ? "Cycle ends today" : "Cycle ends in \(plural(days, "day"))")
          }
        }
        if let assigned = ticket.assignedAt.flatMap(parseInstant), now.timeIntervalSince(assigned) < newAssignmentDays * 86_400 {
          score += newAssignmentPoints
          reasons.append("Newly assigned")
        }
        if ticket.ticket.stateType == "unstarted" { score += readyToStartPoints }
        if ticket.ticket.stateType == "triage" { reasons.append("Needs triage") }
        return UpNextItem(ticket: ticket, score: score, reasons: reasons)
      }
    return stableSorted(ranked) { a, b in
      if a.score != b.score { return a.score > b.score }
      let (left, right) = (a.ticket.priority == 0 ? 9 : a.ticket.priority, b.ticket.priority == 0 ? 9 : b.ticket.priority)
      if left != right { return left < right }
      return a.ticket.createdAt < b.ticket.createdAt
    }
  }

  struct Need {
    let kind: NeedsYouKind
    let tone: Tone
    let title: String
    let detail: String?
    let actionLabel: String
    let action: ItemAction
  }

  /// What each of your open PRs needs from you, if anything; nil means it's waiting on others.
  static func prNeed(_ pr: Pr, ageMessage: (level: TicketAge.Level, text: String)?) -> Need? {
    let details = ItemAction.details(PrKey(pr))
    let label = pr.status.label
    if label == "Merge conflicts" {
      return Need(kind: .conflicts, tone: .bad, title: "Merge conflicts", detail: "with \(pr.baseRef)", actionLabel: "Resolve", action: details)
    }
    if label.hasPrefix("CI failing") {
      let first = pr.checks.failing.first
      let names = pr.checks.failing.map(\.name).joined(separator: ", ")
      if let url = first?.url.flatMap(URL.init(string:)) {
        return Need(kind: .ciFailing, tone: .bad, title: "Required CI failing", detail: names.isEmpty ? nil : names, actionLabel: "Open check", action: .web(url))
      }
      return Need(kind: .ciFailing, tone: .bad, title: "Required CI failing", detail: names.isEmpty ? nil : names, actionLabel: "See checks", action: details)
    }
    if label == "Changes requested" {
      let names = pr.changesRequestedBy.map(\.name).joined(separator: ", ")
      return Need(kind: .changesRequested, tone: .bad, title: "Changes requested", detail: names.isEmpty ? nil : names, actionLabel: "See review", action: details)
    }
    if label == "CodeRabbit wants changes" || label.hasSuffix("to reply to") {
      return Need(kind: .threads, tone: .warn, title: label, detail: nil, actionLabel: "Reply", action: details)
    }
    if label == "Behind base" {
      return Need(kind: .behind, tone: .warn, title: "Behind \(pr.baseRef)", detail: "The branch has to be up to date to merge", actionLabel: "Update", action: details)
    }
    if label == "Ready to merge" {
      return Need(kind: .ready, tone: .good, title: "Ready to merge", detail: nil, actionLabel: "Merge", action: .web(URL(string: pr.url)!))
    }
    if pr.waitingOn == .reviewer, let ageMessage {
      // Who it waits on is listed in full (teams and their members) under the item.
      let alert = ageMessage.level == .alert
      return Need(
        kind: alert ? .stuckReview : .slowReview, tone: alert ? .bad : .warn, title: alert ? "Stuck in review" : "Review is slow",
        detail: ageMessage.text, actionLabel: "Nudge", action: details
      )
    }
    return nil
  }

  /// A PR opened in the last `newPrHours` that's waiting on reviewers with nothing from them yet.
  static func sendForReview(_ pr: Pr, now: Date, newPrHours: Int) -> Need? {
    guard newPrHours > 0, pr.waitingOn == .reviewer, pr.approvals.isEmpty, pr.changesRequestedBy.isEmpty,
          let opened = parseInstant(pr.createdAt), now.timeIntervalSince(opened) < Double(newPrHours) * 3600
    else { return nil }
    return Need(
      kind: .sendForReview, tone: .info, title: "Send for review", detail: "opened \(opened.formatted(.relative(presentation: .named)))",
      actionLabel: "Open", action: .details(PrKey(pr))
    )
  }

  /// How long a status can last before it's flagged, in working days. Review should move faster
  /// than building, so it turns yellow and red sooner.
  private static let ageLimits: [String: (warn: Int, alert: Int)] = ["review": (2, 5), "progress": (3, 7)]
  private static let maxWorkingDaysCounted = 400

  /// Weekdays after `since` up to today, both read in the zone.
  static func workingDaysSince(_ since: String, timeZone: String, now: Date = Date()) -> Int {
    let today = localDate(now, timeZone)
    var count = 0
    var day = addDays(localDate(since, timeZone), 1)
    var steps = 0
    while day <= today && steps < maxWorkingDaysCounted {
      if let date = noon(day) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let weekday = utc.component(.weekday, from: date)
        if weekday != 1 && weekday != 7 { count += 1 }
      }
      day = addDays(day, 1)
      steps += 1
    }
    return count
  }

  /// Only in-flight statuses age: In Progress and In Review, not Merged, Done or Backlog.
  static func ticketAge(_ ticket: Ticket, since: String?, timeZone: String, now: Date = Date()) -> TicketAge? {
    guard let since, ticket.stateType == "started", ticket.state.range(of: "merged", options: .caseInsensitive) == nil else { return nil }
    let kind = ticket.state.range(of: "review", options: .caseInsensitive) != nil ? "review" : "progress"
    let workingDays = workingDaysSince(since, timeZone: timeZone, now: now)
    let limits = ageLimits[kind]!
    let level: TicketAge.Level = workingDays >= limits.alert ? .alert : workingDays >= limits.warn ? .warn : .ok
    let hint = level == .alert
      ? (kind == "review" ? "stuck in review" : "consider flagging or splitting it")
      : (kind == "review" ? "worth a nudge" : "taking a while")
    return TicketAge(
      state: ticket.state, since: since, workingDays: workingDays, level: level,
      message: level == .ok ? nil : "\(ticket.state) for \(plural(workingDays, "working day")), \(hint)"
    )
  }

  static func deadlines(_ tickets: [OpenTicket], today: String, timeZone: String) -> [Deadline] {
    var cycles: [(key: String, cycle: OpenTicket.Cycle, count: Int)] = []
    var projects: [(project: OpenTicket.ProjectInfo, count: Int)] = []
    for ticket in tickets {
      if let cycle = ticket.cycle {
        let key = "\(cycle.number):\(cycle.endsAt)"
        if let index = cycles.firstIndex(where: { $0.key == key }) { cycles[index].count += 1 } else { cycles.append((key, cycle, 1)) }
      }
      if let project = ticket.projectInfo, liveTarget(project, today: today) != nil {
        if let index = projects.firstIndex(where: { $0.project.name == project.name }) {
          projects[index].count += 1
        } else {
          projects.append((project, 1))
        }
      }
    }
    var deadlines: [Deadline] = []
    for (_, cycle, count) in cycles {
      let date = localDate(cycle.endsAt, timeZone)
      let daysLeft = daysBetween(today, date)
      if daysLeft >= 0 && daysLeft <= cycleHorizonDays {
        deadlines.append(Deadline(kind: .cycle, name: "Cycle \(cycle.number)", url: nil, date: date, daysLeft: daysLeft, ticketCount: count))
      }
    }
    for (project, count) in projects {
      let daysLeft = daysBetween(today, project.targetDate!)
      if daysLeft <= projectHorizonDays {
        deadlines.append(Deadline(kind: .project, name: project.name, url: project.url, date: project.targetDate!, daysLeft: daysLeft, ticketCount: count))
      }
    }
    return stableSorted(deadlines) { $0.date < $1.date }
  }

  /// How far back the Linear inbox feed reaches.
  private static let inboxDays = 14.0
  private static let snippetChars = 140

  private static let notificationWords: [String: (InboxKind, String)] = [
    "issueAssignedToYou": (.assigned, "assigned you"),
    "issueUnassignedFromYou": (.assigned, "unassigned you from"),
    "issueNewComment": (.comment, "commented on"),
    "issueCommentMention": (.mention, "mentioned you on"),
    "issueMention": (.mention, "mentioned you on"),
    "issueCommentReaction": (.comment, "reacted to your comment on"),
    "issueEmojiReaction": (.comment, "reacted to"),
    "issueStatusChanged": (.status, "changed the status of"),
    "issuePriorityUrgent": (.priority, "marked urgent"),
    "issueDue": (.priority, "is due:"),
    "issueBlocking": (.status, "unblocked"),
    "issueCreated": (.other, "created"),
    "issueSubscribed": (.other, "subscribed you to"),
    "issueReminder": (.other, "reminder for"),
    "projectAddedAsLead": (.project, "made you lead of"),
    "projectAddedAsMember": (.project, "added you to"),
    "projectNewComment": (.project, "commented on"),
    "projectUpdateCreated": (.project, "posted an update on"),
    "projectUpdateMentionPrompt": (.project, "mentioned you in an update on"),
  ]

  /// First words of a comment or update, as plain text: markdown marks and links reduced to their words.
  static func snippet(_ text: String?) -> String? {
    guard var flat = text else { return nil }
    flat = flat.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
      .replacingOccurrences(of: #"[*_`~>#]+"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    guard !flat.isEmpty else { return nil }
    let units = Array(flat.utf16)
    guard units.count > snippetChars else { return flat }
    return String(decoding: units.prefix(snippetChars), as: UTF16.self)
      .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
  }

  static func inboxItem(_ raw: RawNotification) -> InboxItem {
    let fallbackVerb = raw.type.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).lowercased()
    let (kind, verb) = notificationWords[raw.type] ?? (.other, fallbackVerb)
    let issue = raw.issue
    return InboxItem(
      id: raw.id, kind: kind, at: raw.createdAt, unread: raw.readAt == nil,
      actor: raw.actor.map { InboxItem.Actor(name: $0.name, avatarUrl: $0.avatarUrl) },
      // A status change says where it went, since that's the news.
      verb: raw.type == "issueStatusChanged" && issue != nil ? "moved to \(issue!.state.name)" : verb,
      ticket: issue.map { InboxItem.TicketSummary(key: $0.identifier, title: $0.title, url: $0.url, state: $0.state.name, stateColor: $0.state.color) },
      project: raw.project.map { InboxItem.Project(name: $0.name, url: $0.url) },
      snippet: snippet(raw.comment?.body ?? raw.projectUpdate?.body),
      url: raw.comment?.url ?? raw.projectUpdate?.url ?? issue?.url ?? raw.project?.url
    )
  }

  /// The last two weeks of the inbox, newest first. A comment that mentions you arrives as both a
  /// comment and a mention; the mention is kept.
  static func inbox(_ notifications: [RawNotification], now: Date) -> [InboxItem] {
    let items = stableSorted(
      notifications
        .filter { parseInstant($0.createdAt).map { now.timeIntervalSince($0) < inboxDays * 86_400 } ?? false }
        .map(inboxItem)
    ) { $0.at > $1.at }
    let mentions = items.filter { $0.kind == .mention }
    return items.filter { item in
      item.kind != .comment || !mentions.contains { mention in
        mention.ticket?.key == item.ticket?.key && mention.actor?.name == item.actor?.name
          && abs((parseInstant(mention.at) ?? .distantPast).timeIntervalSince(parseInstant(item.at) ?? .distantPast)) < 60
      }
    }
  }
}
