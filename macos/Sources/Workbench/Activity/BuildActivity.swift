import Foundation

/// Builds a day, week or month of your activity: server/activity/build.ts and cards.ts in Swift.
/// The rules match the web version's; its README describes them.
actor ActivityService {
  static let shared = ActivityService()

  /// GitHub keeps events for 90 days at most, however few there are.
  private static let eventsMaxAge: TimeInterval = 90 * 86_400
  private static let closedTicketTypes: Set = ["completed", "canceled"]
  /// Linked PRs are looked for this far back, so a ticket started weeks ago still finds its PR.
  private static let linkedPrLookbackDays = 60.0
  private static let stateSinceChunk = 25

  private var viewers: [String: String] = [:]

  /// GitHub search takes ISO times with an explicit offset.
  private static func searchTime(_ instant: Date) -> String {
    String(Store.timestamp(instant).dropLast(5)) + "+00:00"
  }

  private static func inRange(_ at: String?, _ range: ActivityRange) -> Bool {
    guard let at, let time = TodayRules.parseInstant(at) else { return false }
    return time >= range.from && time < range.to
  }

  private static func prKey(_ repo: String, _ number: Int) -> String { "\(repo.lowercased())#\(number)" }

  private static func activityPr(_ raw: RawActivityPr) -> ActivityPr {
    ActivityPr(
      repo: raw.repository.nameWithOwner, number: raw.number, title: raw.title, url: raw.url, author: raw.author.map(Derive.userPerson),
      state: raw.state, isDraft: raw.isDraft, createdAt: raw.createdAt, mergedAt: raw.mergedAt, headRef: raw.headRefName,
      ticketKeys: Derive.ticketKeys(headRefName: raw.headRefName, title: raw.title, body: raw.body)
    )
  }

  /// The ticket a branch belongs to, the same way PRs are matched to tickets.
  private static func branchTicketKey(_ branch: String) -> String? {
    Derive.ticketKeys(headRefName: branch, title: "", body: "").first
  }

  private static func eventPrNumber(_ event: RawGitHubEvent) -> Int? {
    event.payload.pull_request?.number ?? event.payload.issue?.number ?? event.payload.number
  }

  private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

  private func viewer(_ token: String) async throws -> String {
    if let known = viewers[token] { return known }
    let login = try await GitHub.viewer(token: token)
    viewers[token] = login
    return login
  }

  func build(_ range: ActivityRange, config: PrConfig) async throws -> ActivityData {
    let viewer = try await viewer(config.githubToken)
    var warnings: [String] = []
    let searchRange = "\(Self.searchTime(range.from))..\(Self.searchTime(range.to))"
    let token = config.githubToken

    async let openedLoad = GitHub.searchActivityPrs("is:pr author:\(viewer) created:\(searchRange)", login: viewer, token: token)
    async let mergedLoad = GitHub.searchActivityPrs("is:pr author:\(viewer) merged:\(searchRange)", login: viewer, token: token)
    // Updated since the range began catches every PR reviewed in it; the reviews' own times decide.
    async let reviewedLoad = GitHub.searchActivityPrs(
      "is:pr reviewed-by:\(viewer) -author:\(viewer) updated:>=\(Self.searchTime(range.from))", login: viewer, token: token
    )
    async let feedLoad = Result { try await GitHub.userEvents(viewer, token: token) }
    async let linearLoad = Result {
      try await Linear.myIssueActivity(from: Store.timestamp(range.from), to: Store.timestamp(range.to), apiKey: config.linearApiKey)
    }
    let (opened, merged, reviewed) = try await (openedLoad, mergedLoad, reviewedLoad)
    let feed: (events: [RawGitHubEvent], capped: Bool)
    switch await feedLoad {
    case let .success(value): feed = value
    case let .failure(error):
      warnings.append("GitHub events: \(error.localizedDescription)")
      feed = ([], true)
    }
    let issues: [LinearIssueActivity]
    switch await linearLoad {
    case let .success(value):
      issues = value.issues
      if value.truncated { warnings.append("Linear: too many tickets changed since then; some ticket moves may be missing.") }
    case let .failure(error):
      warnings.append("Linear: \(error.localizedDescription)")
      issues = []
    }

    // Every PR the range touches, by repo#number: from search, then the events' leftovers looked up.
    var prs = OrderedPrs()
    for raw in opened + merged + reviewed { prs[Self.prKey(raw.repository.nameWithOwner, raw.number)] = Self.activityPr(raw) }
    let rangeEvents = feed.events.filter { Self.inRange($0.created_at, range) }
    var missing: [(key: String, repo: String, number: Int)] = []
    for event in rangeEvents {
      guard let number = Self.eventPrNumber(event) else { continue }
      let key = Self.prKey(event.repo.name, number)
      if prs[key] == nil && !missing.contains(where: { $0.key == key }) { missing.append((key, event.repo.name, number)) }
    }
    if !missing.isEmpty {
      for raw in try await GitHub.prsByNumber(missing.map { ($0.repo, $0.number) }, token: token) {
        prs[Self.prKey(raw.repository.nameWithOwner, raw.number)] = Self.activityPr(raw)
      }
    }

    // Tickets: everything Linear reported, plus any key named by a PR or pushed branch.
    var tickets: [String: Ticket] = [:]
    for issue in issues { tickets[issue.identifier] = issue.ticket }
    var keys: [String] = []
    func note(_ key: String) { if !keys.contains(key) { keys.append(key) } }
    for pr in prs.values { pr.ticketKeys.forEach(note) }
    for event in rangeEvents where event.type == "PushEvent" {
      if let ref = event.payload.ref, let key = Self.branchTicketKey(ref.replacingOccurrences(of: "refs/heads/", with: "")) { note(key) }
    }
    let unknown = keys.filter { tickets[$0] == nil }
    if !unknown.isEmpty {
      do {
        for (key, ticket) in try await Linear.tickets(unknown, apiKey: config.linearApiKey) { tickets[key] = ticket }
      } catch is NotConfigured {
      } catch {
        warnings.append("Linear ticket lookup: \(error.localizedDescription)")
      }
    }

    let ticketActivity = Self.transitions(issues, range)

    let oldest = feed.events.map(\.created_at).min()
    let coverageFrom = feed.capped ? oldest : Store.timestamp(Date(timeIntervalSinceNow: -Self.eventsMaxAge))
    let coverage = coverageFrom.flatMap(TodayRules.parseInstant)
    let dayByDay: DayByDayCoverage = coverage == nil ? .unavailable : coverage! <= range.from ? .complete : coverage! < range.to ? .partial : .unavailable

    let shipped = TodayRules.stableSorted(merged.map { raw -> ShippedPr in
      let pr = prs[Self.prKey(raw.repository.nameWithOwner, raw.number)]!
      let prTickets = pr.ticketKeys.compactMap { tickets[$0] }
      return ShippedPr(pr: pr, tickets: prTickets, ticketLagging: prTickets.contains { !Self.closedTicketTypes.contains($0.stateType) })
    }) { ($0.pr.mergedAt ?? "") > ($1.pr.mergedAt ?? "") }

    let reviewsGiven = TodayRules.stableSorted(reviewed.compactMap { raw -> ReviewGiven? in
      let reviews = (raw.reviews?.nodes ?? [])
        .filter { $0.state != "PENDING" && Self.inRange($0.submittedAt, range) }
        .map { ReviewGiven.Review(state: $0.state, at: $0.submittedAt!, url: $0.url, comments: $0.comments.totalCount) }
      return reviews.isEmpty ? nil : ReviewGiven(pr: prs[Self.prKey(raw.repository.nameWithOwner, raw.number)]!, reviews: reviews)
    }) { ($0.reviews.last?.at ?? "") > ($1.reviews.last?.at ?? "") }

    if dayByDay != .complete {
      warnings.append(
        dayByDay == .partial
          ? "Pushes and replies start \(TodayRules.localDate(coverageFrom!, range.timeZone)): GitHub only keeps your last 300 events. PRs, reviews and tickets are complete."
          : "No pushes or replies this far back: GitHub only keeps your last 300 events. PRs, reviews and ticket moves are still complete."
      )
    }

    let openedPrs = opened.map { prs[Self.prKey($0.repository.nameWithOwner, $0.number)]! }
    let days = Self.days(
      rangeEvents, range: range, viewer: viewer, prs: prs, tickets: tickets, ticketActivity: ticketActivity,
      coverageFrom: coverageFrom, opened: openedPrs, merged: shipped.map(\.pr), reviewsGiven: reviewsGiven
    )
    // Linked PRs cost two more lookups, so only the Day view asks for them; ages every view needs.
    async let cards = range.span == .day ? ticketCards(viewer: viewer, range: range, days: days, known: prs.values, config: config) : ([:], [])
    async let ages = ticketAges(days: days, tickets: tickets, timeZone: range.timeZone, apiKey: config.linearApiKey)
    let (cardResult, ageResult) = await (cards, ages)
    warnings += cardResult.1 + ageResult.1

    return ActivityData(
      range: range, viewer: viewer,
      totals: ActivityTotals(
        prsOpened: opened.count, prsMerged: merged.count, prsReviewed: reviewsGiven.count,
        ticketsCompleted: ticketActivity.filter { $0.transitions.contains { $0.toType == "completed" } }.count,
        pushes: dayByDay == .complete ? rangeEvents.filter { $0.type == "PushEvent" }.count : nil
      ),
      dayByDay: dayByDay, coverageFrom: coverageFrom, days: days, shipped: shipped,
      opened: TodayRules.stableSorted(openedPrs) { $0.createdAt > $1.createdAt }, reviewsGiven: reviewsGiven,
      tickets: ticketActivity, ticketCards: cardResult.0, ticketAges: ageResult.0, warnings: warnings, fetchedAt: Date()
    )
  }

  // MARK: Tickets

  private static func transitions(_ issues: [LinearIssueActivity], _ range: ActivityRange) -> [TicketActivity] {
    let activity = issues
      .map { issue in
        TicketActivity(
          ticket: issue.ticket,
          created: issue.creator?.isMe == true && inRange(issue.createdAt, range),
          transitions: TodayRules.stableSorted(
            issue.history.nodes
              .filter { $0.toState != nil && inRange($0.createdAt, range) }
              .map { TicketTransition(at: $0.createdAt, from: $0.fromState?.name, to: $0.toState!.name, toType: $0.toState!.type, by: $0.actor?.name) }
          ) { $0.at < $1.at }
        )
      }
      .filter { $0.created || !$0.transitions.isEmpty }
    return TodayRules.stableSorted(activity) { ($0.transitions.last?.at ?? "") > ($1.transitions.last?.at ?? "") }
  }

  private static func ticketKeys(in days: [ActivityDay]) -> [String] {
    var keys: [String] = []
    for day in days {
      for group in day.groups {
        if let key = group.ticket?.key, !keys.contains(key) { keys.append(key) }
      }
    }
    return keys
  }

  /// Status age for every in-flight ticket the range touches.
  private func ticketAges(days: [ActivityDay], tickets: [String: Ticket], timeZone: String, apiKey: String) async -> ([String: TicketAge], [String]) {
    let aging = Self.ticketKeys(in: days).compactMap { tickets[$0] }
      .filter { $0.stateType == "started" && $0.state.range(of: "merged", options: .caseInsensitive) == nil }
    var since: [String: String] = [:]
    do {
      let keys = aging.map(\.key)
      for start in stride(from: 0, to: keys.count, by: Self.stateSinceChunk) {
        since.merge(try await Linear.stateSince(Array(keys[start ..< min(start + Self.stateSinceChunk, keys.count)]), apiKey: apiKey)) { $1 }
      }
    } catch is NotConfigured {
      return ([:], [])
    } catch {
      return ([:], ["Linear status history: \(error.localizedDescription)"])
    }
    var ages: [String: TicketAge] = [:]
    for ticket in aging {
      if let age = TodayRules.ticketAge(ticket, since: since[ticket.key], timeZone: timeZone) { ages[ticket.key] = age }
    }
    return (ages, [])
  }

  /// For the Day view: every ticket in the day with the PRs that belong to it, open ones carrying
  /// the PR list's status.
  private func ticketCards(viewer: String, range: ActivityRange, days: [ActivityDay], known: [ActivityPr], config: PrConfig) async -> ([String: [LinkedPr]], [String]) {
    let keys = Self.ticketKeys(in: days)
    guard !keys.isEmpty else { return ([:], []) }
    var warnings: [String] = []
    let lookbackFrom = range.from.addingTimeInterval(-Self.linkedPrLookbackDays * 86_400)
    async let recentLoad = Result {
      try await GitHub.searchActivityPrs("is:pr author:\(viewer) updated:>=\(Self.searchTime(lookbackFrom))", login: viewer, token: config.githubToken)
    }
    async let openLoad = try? PrService.shared.load(.mine, config: config, maxAge: 60)
    let recent: [RawActivityPr]
    switch await recentLoad {
    case let .success(value): recent = value
    case let .failure(error):
      warnings.append("Couldn't look up linked PRs: \(error.localizedDescription)")
      recent = []
    }
    let open = await openLoad?.open ?? []

    var pool: [ActivityPr] = []
    for pr in known where !pool.contains(where: { $0.url == pr.url }) { pool.append(pr) }
    for raw in recent where !pool.contains(where: { $0.url == raw.url }) {
      pool.append(ActivityPr(
        repo: raw.repository.nameWithOwner, number: raw.number, title: raw.title, url: raw.url, author: nil, state: raw.state,
        isDraft: raw.isDraft, createdAt: raw.createdAt, mergedAt: raw.mergedAt, headRef: raw.headRefName, ticketKeys: []
      ))
    }
    // Search results arrive without ticket keys worked out; match them the same way PRs are matched.
    for raw in recent {
      if let index = pool.firstIndex(where: { $0.url == raw.url }), pool[index].ticketKeys.isEmpty {
        pool[index].ticketKeys = Derive.ticketKeys(headRefName: raw.headRefName, title: raw.title, body: raw.body)
      }
    }
    let statusByUrl = Dictionary(open.map { ($0.url, $0.status) }, uniquingKeysWith: { first, _ in first })
    let rank: [ActivityPr.State: Int] = [.OPEN: 0, .MERGED: 1, .CLOSED: 2]
    var cards: [String: [LinkedPr]] = [:]
    for key in keys {
      cards[key] = TodayRules.stableSorted(pool.filter { $0.ticketKeys.contains(key) }) {
        rank[$0.state]! != rank[$1.state]! ? rank[$0.state]! < rank[$1.state]! : $0.createdAt > $1.createdAt
      }
      .map { LinkedPr(pr: $0, status: $0.state == .OPEN ? statusByUrl[$0.url] : nil) }
    }
    return (cards, warnings)
  }

  // MARK: Days

  private struct EntryDraft {
    var entry: DayEntry
    var count: Int
  }

  private struct GroupDraft {
    let key: String
    let ticketKey: String?
    let title: String
    var entries: [(key: String, draft: EntryDraft)] = []
  }

  private struct ReviewDraft {
    var entry: DayEntry
    let pr: ActivityPr
    var count: Int
    var comments: Int
  }

  private struct DayDraft {
    var groups: [GroupDraft] = []
    var reviews: [(key: String, draft: ReviewDraft)] = []
  }

  /// The range, day by day, from the events feed. Pushes and replies are counted per ticket per
  /// day; reviews of other people's PRs are listed apart. Before the feed begins, search still knows
  /// when PRs were opened, merged and reviewed, and ticket moves count as the day's work too.
  private static func days(
    _ events: [RawGitHubEvent], range: ActivityRange, viewer: String, prs: OrderedPrs, tickets: [String: Ticket],
    ticketActivity: [TicketActivity], coverageFrom: String?, opened: [ActivityPr], merged: [ActivityPr], reviewsGiven: [ReviewGiven]
  ) -> [ActivityDay] {
    var days: [String: DayDraft] = [:]

    /// Same-kind entries in a group on a day fold into one, counted.
    func add(_ at: String, group: (key: String, ticketKey: String?, title: String), entryKey: String, _ entry: DayEntry) {
      let date = TodayRules.localDate(at, range.timeZone)
      var day = days[date] ?? DayDraft()
      var groupIndex = day.groups.firstIndex { $0.key == group.key }
      if groupIndex == nil {
        day.groups.append(GroupDraft(key: group.key, ticketKey: group.ticketKey, title: group.title))
        groupIndex = day.groups.count - 1
      }
      if let entryIndex = day.groups[groupIndex!].entries.firstIndex(where: { $0.key == entryKey }) {
        day.groups[groupIndex!].entries[entryIndex].draft.count += 1
        if at > day.groups[groupIndex!].entries[entryIndex].draft.entry.at { day.groups[groupIndex!].entries[entryIndex].draft.entry.at = at }
      } else {
        day.groups[groupIndex!].entries.append((entryKey, EntryDraft(entry: entry, count: 1)))
      }
      days[date] = day
    }

    func groupFor(_ repo: String, branch: String?, pr: ActivityPr?) -> (key: String, ticketKey: String?, title: String) {
      let ticketKey = branch.flatMap(branchTicketKey) ?? pr?.ticketKeys.first
      let key = ticketKey ?? (pr.map { prKey($0.repo, $0.number) } ?? "\(repo):\(branch ?? "null")")
      let title = ticketKey.flatMap { tickets[$0]?.title } ?? pr?.title ?? branch ?? repo
      return (key, ticketKey, title)
    }

    func review(_ at: String, key: String, update: (inout ReviewDraft?) -> Void) {
      let date = TodayRules.localDate(at, range.timeZone)
      var day = days[date] ?? DayDraft()
      let index = day.reviews.firstIndex { $0.key == key }
      var draft = index.map { day.reviews[$0].draft }
      update(&draft)
      if let draft {
        if let index { day.reviews[index].draft = draft } else { day.reviews.append((key, draft)) }
      }
      days[date] = day
    }

    let rankOf: [DayEntryKind: Int] = [.reviewed: 0, .approved: 1, .changesRequested: 2]
    for event in events {
      let repo = event.repo.name
      let number = eventPrNumber(event)
      let pr = number.flatMap { prs[prKey(repo, $0)] }
      let own = pr.map { $0.author?.id.lowercased() == viewer.lowercased() } ?? true

      switch event.type {
      case "PushEvent":
        guard let ref = event.payload.ref else { break }
        let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        guard !branch.isEmpty else { break }
        add(event.created_at, group: groupFor(repo, branch: branch, pr: nil), entryKey: "pushed",
            DayEntry(kind: .pushed, at: event.created_at, text: "pushed", url: nil))
      case "PullRequestEvent":
        guard let pr, let action = event.payload.action, ["opened", "merged", "closed", "reopened"].contains(action),
              let kind = DayEntryKind(rawValue: action) else { break }
        add(event.created_at, group: groupFor(repo, branch: pr.headRef, pr: pr), entryKey: "\(action)#\(pr.number)",
            DayEntry(kind: kind, at: event.created_at, text: "\(action) #\(pr.number)", url: pr.url))
      case "PullRequestReviewCommentEvent", "PullRequestReviewEvent":
        guard let pr else { break }
        if own {
          // Answering feedback on your own PR: GitHub logs each reply as a comment and a review.
          guard event.type == "PullRequestReviewCommentEvent" else { break }
          add(event.created_at, group: groupFor(repo, branch: pr.headRef, pr: pr), entryKey: "replied#\(pr.number)",
              DayEntry(kind: .replied, at: event.created_at, text: "replied to review comments on #\(pr.number)", url: event.payload.comment?.html_url ?? pr.url))
          break
        }
        let key = prKey(repo, pr.number)
        if event.type == "PullRequestReviewCommentEvent" {
          review(event.created_at, key: key) { draft in
            if draft != nil {
              draft!.comments += 1
            } else {
              draft = ReviewDraft(entry: DayEntry(kind: .reviewed, at: event.created_at, text: "", url: event.payload.comment?.html_url ?? pr.url), pr: pr, count: 0, comments: 1)
            }
          }
          break
        }
        let kind: DayEntryKind = switch event.payload.review?.state {
        case "approved": .approved
        case "changes_requested": .changesRequested
        default: .reviewed
        }
        // The strongest verdict of the day wins: changes requested, then approved, then comments.
        review(event.created_at, key: key) { draft in
          if draft != nil {
            draft!.count += 1
            if rankOf[kind]! > rankOf[draft!.entry.kind]! {
              draft!.entry.kind = kind
              draft!.entry.url = event.payload.review?.html_url ?? draft!.entry.url
            }
          } else {
            draft = ReviewDraft(entry: DayEntry(kind: kind, at: event.created_at, text: "", url: event.payload.review?.html_url ?? pr.url), pr: pr, count: 1, comments: 0)
          }
        }
      case "IssueCommentEvent":
        guard let pr, event.payload.issue?.pull_request != nil else { break }
        add(event.created_at, group: groupFor(repo, branch: pr.headRef, pr: pr), entryKey: "commented#\(pr.number)",
            DayEntry(kind: .commented, at: event.created_at, text: "commented on #\(pr.number)\(own ? "" : " by \(pr.author?.name ?? "someone")")",
                     url: event.payload.comment?.html_url ?? pr.url))
      default: break
      }
    }

    // Before the events feed begins, search still knows when PRs were opened, merged and reviewed.
    let uncovered = { (at: String?) -> Bool in
      guard let at, inRange(at, range) else { return false }
      return coverageFrom == nil || at < coverageFrom!
    }
    for (list, action) in [(opened, DayEntryKind.opened), (merged, .merged)] {
      for pr in list {
        let at = action == .opened ? pr.createdAt : pr.mergedAt
        guard uncovered(at), let at else { continue }
        add(at, group: groupFor(pr.repo, branch: pr.headRef, pr: pr), entryKey: "\(action.rawValue)#\(pr.number)",
            DayEntry(kind: action, at: at, text: "\(action.rawValue) #\(pr.number)", url: pr.url))
      }
    }
    for given in reviewsGiven {
      for item in given.reviews where uncovered(item.at) {
        review(item.at, key: prKey(given.pr.repo, given.pr.number)) { draft in
          guard draft == nil else { return }
          let kind: DayEntryKind = item.state == "APPROVED" ? .approved : item.state == "CHANGES_REQUESTED" ? .changesRequested : .reviewed
          draft = ReviewDraft(entry: DayEntry(kind: kind, at: item.at, text: "", url: item.url), pr: given.pr, count: 1, comments: item.comments)
        }
      }
    }

    // Ticket moves count as the day's work on that ticket too.
    for activity in ticketActivity {
      for move in activity.transitions {
        add(move.at, group: (activity.ticket.key, activity.ticket.key, activity.ticket.title), entryKey: "ticket-\(move.to)",
            DayEntry(kind: .ticket, at: move.at, text: "moved to \(move.to)", url: activity.ticket.url))
      }
    }

    let verdict: [DayEntryKind: String] = [.approved: "approved", .changesRequested: "requested changes on", .reviewed: "reviewed"]
    let coverage = coverageFrom.flatMap(TodayRules.parseInstant)
    return days.keys.sorted().map { date in
      let day = days[date]!
      let groups = day.groups.map { group in
        DayGroup(
          key: group.key, ticket: group.ticketKey.flatMap { tickets[$0] }, title: group.title,
          entries: TodayRules.stableSorted(group.entries.map(\.draft)) { $0.entry.at < $1.entry.at }.map { draft in
            var entry = draft.entry
            if entry.kind == .pushed {
              entry.text = "pushed\(draft.count > 1 ? " \(draft.count)×" : "")"
            } else if entry.kind == .replied {
              entry.text = "replied to \(plural(draft.count, "review comment")) on \(entry.text.components(separatedBy: " on ").dropFirst().first ?? "")"
            }
            return entry
          }
        )
      }
      return ActivityDay(
        date: date,
        groups: TodayRules.stableSorted(groups) { ($0.entries.last?.at ?? "") > ($1.entries.last?.at ?? "") },
        reviews: day.reviews.map { _, draft in
          var entry = draft.entry
          entry.text = "\(verdict[entry.kind] ?? "reviewed") #\(draft.pr.number)\(draft.comments > 0 ? " · \(plural(draft.comments, "comment"))" : "")"
          return DayReview(entry: entry, pr: draft.pr)
        },
        detailed: coverage.map { $0 <= CalendarTime.startOfDate(date, range.timeZone) } ?? false
      )
    }
  }
}

/// PRs by repo#number in the order first seen, like a JavaScript Map: later writes replace the
/// value but keep its place.
struct OrderedPrs: Sendable {
  private var keys: [String] = []
  private var byKey: [String: ActivityPr] = [:]

  subscript(key: String) -> ActivityPr? {
    get { byKey[key] }
    set {
      if byKey[key] == nil, newValue != nil { keys.append(key) }
      byKey[key] = newValue
    }
  }

  var values: [ActivityPr] { keys.compactMap { byKey[$0] } }
}
