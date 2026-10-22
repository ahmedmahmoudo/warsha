import Foundation

// Turning GitHub's raw PR into the details page: server/prs/detail.ts in Swift.

enum BuildDetail {
  private static let excerptChars = 600
  private static let maxCommitHeadlines = 5
  /// Consecutive events of the same kind by the same person this close together read as one.
  private static let mergeWindow: TimeInterval = 10 * 60

  static func excerpt(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    // JavaScript counts UTF-16 units; match it so excerpts end in the same place.
    let units = Array(trimmed.utf16)
    guard units.count > excerptChars else { return trimmed }
    let cut = String(decoding: units.prefix(excerptChars), as: UTF16.self)
    return cut.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
  }

  private static func isBot(_ actor: RawDetailActor?) -> Bool {
    guard let actor else { return false }
    return actor.__typename == "Bot" || actor.login.hasSuffix("[bot]") || Derive.isCodeRabbit(actor.login)
  }

  private static func person(_ actor: RawDetailActor?) -> Person? {
    actor.map { Derive.userPerson($0.actor) }
  }

  private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

  private static func eventTitle(_ item: RawTimelineItem) -> String? {
    switch item.__typename {
    case "ReadyForReviewEvent": "marked this ready for review"
    case "ConvertToDraftEvent": "converted this to a draft"
    case "MergedEvent": "merged this"
    case "ClosedEvent": "closed this"
    case "ReopenedEvent": "reopened this"
    case "AddedToMergeQueueEvent": "added this to the merge queue"
    case "RemovedFromMergeQueueEvent":
      "removed this from the merge queue\(item.reason.map { " (\($0.lowercased().replacingOccurrences(of: "_", with: " ")))" } ?? "")"
    case "HeadRefForcePushedEvent": "force-pushed the branch"
    case "ReviewDismissedEvent": "dismissed a review"
    case "BaseRefChangedEvent": "changed the base from \(item.previousRefName ?? "") to \(item.currentRefName ?? "")"
    default: nil
    }
  }

  private static func timelineEntry(_ item: RawTimelineItem) -> ActivityItem? {
    guard let at = item.createdAt ?? item.commit?.committedDate, let id = item.id else { return nil }
    switch item.__typename {
    case "PullRequestCommit":
      return ActivityItem(
        id: id, kind: .commits, at: at, actor: item.commit?.author?.user.map(Derive.userPerson), isBot: false,
        title: "pushed 1 commit", body: item.commit?.messageHeadline, url: item.url
      )
    case "PullRequestReview":
      let kind: ActivityItem.Kind = item.state == "APPROVED" ? .approved : item.state == "CHANGES_REQUESTED" ? .changesRequested : .reviewed
      let title =
        kind == .approved ? "approved"
          : kind == .changesRequested ? "requested changes"
          : item.state == "DISMISSED" ? "reviewed (since dismissed)"
          : item.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "reviewed"
          : "commented on the code"
      return ActivityItem(
        id: id, kind: kind, at: at, actor: person(item.author), isBot: isBot(item.author), title: title,
        body: excerpt(item.bodyText), url: item.url
      )
    case "IssueComment":
      return ActivityItem(
        id: id, kind: .comment, at: at, actor: person(item.author), isBot: isBot(item.author), title: "commented",
        body: excerpt(item.bodyText), url: item.url
      )
    case "ReviewRequestedEvent":
      let reviewer = item.requestedReviewer?.login ?? item.requestedReviewer?.name ?? "someone"
      return ActivityItem(
        id: id, kind: .reviewRequested, at: at, actor: person(item.actor), isBot: isBot(item.actor),
        title: "requested review from \(reviewer)", body: nil, url: item.url
      )
    default:
      guard let title = eventTitle(item) else { return nil }
      let body = item.__typename == "ReviewDismissedEvent" ? excerpt(item.dismissalMessage) : nil
      return ActivityItem(
        id: id, kind: .event, at: at, actor: person(item.actor), isBot: isBot(item.actor), title: title, body: body, url: item.url
      )
    }
  }

  /// Folds runs of commits, review requests and inline-comment reviews into one line each.
  private static func mergeRuns(_ items: [ActivityItem]) -> [ActivityItem] {
    var merged: [ActivityItem] = []
    for item in items {
      if var last = merged.last, last.kind == item.kind, last.actor?.id == item.actor?.id,
         let then = parseDate(last.at), let now = parseDate(item.at), now.timeIntervalSince(then) < mergeWindow {
        if item.kind == .commits {
          let headlines = ((last.body ?? "").components(separatedBy: "\n") + [item.body ?? ""]).filter { !$0.isEmpty }
          let count = (Int(last.title.firstMatch(of: /\d+/).map { String($0.output) } ?? "1") ?? 1) + 1
          last.at = item.at
          last.title = "pushed \(plural(count, "commit"))"
          last.body = headlines.joined(separator: "\n")
          merged[merged.count - 1] = last
          continue
        } else if item.kind == .reviewRequested {
          last.title += ", " + item.title.replacingOccurrences(of: "requested review from ", with: "")
          merged[merged.count - 1] = last
          continue
        } else if item.kind == .reviewed && item.body == nil && last.body == nil {
          last.at = item.at
          merged[merged.count - 1] = last
          continue
        }
      }
      merged.append(item)
    }
    // Long pushes keep the latest headlines and say how many more there were.
    return merged.map { item in
      guard item.kind == .commits, let body = item.body else { return item }
      let headlines = body.components(separatedBy: "\n")
      guard headlines.count > maxCommitHeadlines else { return item }
      var trimmed = item
      trimmed.body = (headlines.suffix(maxCommitHeadlines) + ["…and \(headlines.count - maxCommitHeadlines) earlier"]).joined(separator: "\n")
      return trimmed
    }
  }

  private static func activity(_ raw: GithubPrDetail) -> [ActivityItem] {
    let opened = ActivityItem(
      id: "\(raw.base.id)-opened", kind: .opened, at: raw.base.createdAt, actor: raw.base.author.map(Derive.userPerson),
      isBot: false, title: "opened this pull request", body: nil, url: raw.base.url
    )
    // Newest first: what happened last is what the reader came for.
    return mergeRuns([opened] + raw.timelineItems.nodes.compactMap(timelineEntry)).reversed()
  }

  private static func summary(_ raw: GithubPrDetail, _ activity: [ActivityItem]) -> ActivitySummary {
    let comments = activity.filter { $0.kind == .comment }
    return ActivitySummary(
      commits: raw.timelineItems.nodes.filter { $0.__typename == "PullRequestCommit" }.count,
      approvals: activity.filter { $0.kind == .approved && !$0.isBot }.count,
      changeRequests: activity.filter { $0.kind == .changesRequested && !$0.isBot }.count,
      comments: comments.filter { !$0.isBot }.count,
      botComments: comments.filter(\.isBot).count,
      lastActivityAt: activity.first?.at ?? raw.base.updatedAt
    )
  }

  private static func openThreads(_ raw: GithubPrDetail) -> [ReviewThread] {
    raw.threads.nodes
      .filter { !$0.isResolved }
      .compactMap { thread in
        guard let first = thread.comments.nodes.first else { return nil }
        return ReviewThread(
          id: thread.id, path: thread.path, line: thread.line, author: person(first.author), isBot: isBot(first.author),
          isOutdated: thread.isOutdated, body: excerpt(first.bodyText) ?? "", replies: thread.comments.totalCount - 1,
          url: first.url, createdAt: first.createdAt,
          replied: thread.lastComment?.nodes.last?.author.map { $0.login.caseInsensitiveCompare(raw.base.author?.login ?? "") == .orderedSame } ?? false
        )
      }
      .sorted { ($0.isOutdated ? 1 : 0, $0.createdAt) < ($1.isOutdated ? 1 : 0, $1.createdAt) }
  }

  private static func changeRequests(_ raw: GithubPrDetail, _ threads: [ReviewThread]) -> [ChangeRequest] {
    raw.reviews.nodes
      .filter { $0.state == "CHANGES_REQUESTED" && $0.author != nil && !isBot($0.author) }
      .map { review in
        let author = review.author!
        return ChangeRequest(
          reviewer: Derive.userPerson(author.actor), at: review.submittedAt ?? raw.base.updatedAt, body: excerpt(review.bodyText) ?? "",
          url: review.url, threadIds: threads.filter { $0.author?.id == author.login }.map(\.id)
        )
      }
  }

  private static func mergeReadiness(_ raw: GithubPrDetail, _ pr: Pr, _ checks: [CheckItem], _ threads: [ReviewThread]) -> MergeReadiness {
    guard raw.state == "OPEN" else { return MergeReadiness() }
    let queue = raw.mergeQueueEntry.map { MergeQueue(position: $0.position, state: $0.state, enqueuedAt: $0.enqueuedAt) }
    let rules = Derive.mergeRules(raw.base.baseRef)
    var blockers: [MergeBlocker] = []
    var notes: [String] = []
    let failing = checks.filter { $0.required && $0.state == .failed }
    let pending = checks.filter { $0.required && $0.state == .pending }
    let advisoryFailing = checks.filter { !$0.required && $0.state == .failed }
    let status = raw.base.mergeStateStatus

    if raw.base.isDraft { blockers.append(MergeBlocker(kind: .draft, label: "Still a draft", items: [])) }
    if status == "DIRTY" { blockers.append(MergeBlocker(kind: .conflicts, label: "Merge conflicts with the base branch", items: [])) }
    if status == "BEHIND" {
      if rules.strictChecks {
        blockers.append(MergeBlocker(kind: .behind, label: "Behind \(raw.base.baseRefName); update the branch", items: []))
      } else {
        notes.append("Behind \(raw.base.baseRefName), which this branch doesn't require updating for")
      }
    }
    if !failing.isEmpty {
      blockers.append(MergeBlocker(kind: .ciFailing, label: "\(plural(failing.count, "required check")) failing", items: failing.map(\.name)))
    }
    if !pending.isEmpty {
      blockers.append(MergeBlocker(kind: .ciPending, label: "\(plural(pending.count, "required check")) still running", items: pending.map(\.name)))
    }
    if !pr.changesRequestedBy.isEmpty {
      blockers.append(MergeBlocker(kind: .changesRequested, label: "Changes requested", items: pr.changesRequestedBy.map(\.name)))
    }
    if let gate = pr.reviewGate, !gate.codeOwners.isEmpty {
      blockers.append(MergeBlocker(
        kind: .codeOwners, label: "Needs \(plural(gate.codeOwners.count, "code-owner approval"))",
        items: gate.codeOwners.map { $0.map(\.name).joined(separator: " or ") }
      ))
    }
    if let gate = pr.reviewGate, gate.approvalsNeeded > 0 {
      blockers.append(MergeBlocker(kind: .approvals, label: "Needs \(plural(gate.approvalsNeeded, "more approval"))", items: []))
    }
    if rules.threadResolution && !threads.isEmpty {
      blockers.append(MergeBlocker(kind: .threads, label: plural(threads.count, "unresolved conversation"), items: []))
    } else if !threads.isEmpty {
      notes.append("\(plural(threads.count, "unresolved conversation")), not required to merge")
    }

    if !advisoryFailing.isEmpty { notes.append("\(plural(advisoryFailing.count, "advisory check")) failing, not required to merge") }
    if pr.coderabbit.review == .changesRequested { notes.append("CodeRabbit wants changes") }
    if let gate = pr.reviewGate, !gate.complete { notes.append("Some changed files couldn't be read, so code owners may be incomplete") }

    return MergeReadiness(applicable: true, ready: blockers.isEmpty, queue: queue, blockers: blockers, notes: notes)
  }

  private static func state(_ raw: GithubPrDetail, _ merge: MergeReadiness) -> PrState {
    if raw.state == "MERGED" { return .merged }
    if raw.state == "CLOSED" { return .closed }
    if merge.queue != nil { return .queued }
    if raw.base.isDraft { return .draft }
    return merge.ready ? .ready : .open
  }

  static func detail(_ raw: GithubPrDetail, pr: Pr, actions: PrActions) -> PrDetail {
    let checks = Derive.checks(commits: raw.base.commits, mergedAt: raw.base.mergedAt, baseRef: raw.base.baseRef)
    let threads = openThreads(raw)
    var merge = mergeReadiness(raw, pr, checks, threads)
    // GitHub only says BEHIND when the base requires an up-to-date branch; the comparison always knows.
    if let behind = actions.updateBranch, merge.applicable, !merge.blockers.contains(where: { $0.kind == .behind }) {
      merge.notes = merge.notes.filter { !$0.hasPrefix("Behind ") }
        + ["\(plural(behind.behindBy, "commit")) behind \(behind.base), which isn't required to merge"]
    }
    let activity = activity(raw)
    return PrDetail(
      pr: pr, state: state(raw, merge), headOid: raw.headRefOid, body: raw.body, images: DescriptionImages.extract(raw.bodyHTML),
      closedAt: raw.closedAt, checks: checks, merge: merge, activity: activity, activitySummary: summary(raw, activity),
      openThreads: threads, changeRequests: changeRequests(raw, threads), actions: actions, fetchedAt: Date()
    )
  }
}

/// The description's images, taken from GitHub's rendering of it: its links to attachments are
/// signed for a few minutes, which an image view can load without the token. src/components/Gallery.tsx.
enum DescriptionImages {
  /// Badges and icons stay out of the gallery; they're part of the text, not screenshots.
  private static var inlineHosts: Regex<(Substring, Substring, Substring)> { #/(^|\.)(shields\.io|badgen\.net)$/# }
  private static let maxInlineHeight = 32

  static func extract(_ html: String) -> [GalleryImage] {
    var images: [GalleryImage] = []
    for match in html.matches(of: /<img\b[^>]*>/) {
      let tag = String(match.output)
      guard let src = attribute("src", in: tag) else { continue }
      let original = attribute("data-canonical-src", in: tag) ?? src
      guard let host = URL(string: original)?.host, host.firstMatch(of: inlineHosts) == nil else { continue }
      if let height = attribute("height", in: tag).flatMap(Int.init), height > 0, height <= maxInlineHeight { continue }
      let name = URL(string: original)?.lastPathComponent.removingPercentEncoding ?? "image"
      let alt = attribute("alt", in: tag)?.trimmingCharacters(in: .whitespaces)
      let caption = alt.flatMap { !$0.isEmpty && $0 != name && $0.lowercased() != "image" ? $0 : nil } ?? name
      if !images.contains(where: { $0.src == src }) { images.append(GalleryImage(src: src, original: original, caption: caption)) }
    }
    return images
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    guard let match = tag.firstMatch(of: try! Regex(#"\b\#(name)="([^"]*)""#)), let value = match.output[1].substring else { return nil }
    return String(value)
      .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
  }
}
