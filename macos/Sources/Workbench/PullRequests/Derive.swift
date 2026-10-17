import Foundation

// Turning GitHub's raw PR into what the page shows: server/prs/derive.ts in Swift. The rules and
// their order match the web version's; its README describes them.

enum Derive {
  private static let failingConclusions: Set = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
  private static let skippedConclusions: Set = ["SKIPPED", "NEUTRAL", "STALE"]
  private static let closedTicketTypes: Set = ["completed", "canceled"]
  private static let notStartedTicketTypes: Set = ["backlog", "unstarted", "triage"]

  private static let branchKey = try! NSRegularExpression(pattern: #"(?:^|[/_-])([a-z]{2,6}-\d{1,6})(?=\b|[/_-])"#, options: .caseInsensitive)
  private static let titleKey = try! NSRegularExpression(pattern: #"\b[A-Z]{2,6}-\d{1,6}\b"#)
  private static let linearLink = try! NSRegularExpression(pattern: #"linear\.app/[^/\s]+/issue/([A-Z]{2,6}-\d{1,6})"#)

  /// Branch names are lower-cased by Linear ("feature/mx-2473-…"), so the branch is matched
  /// case-insensitively but only its first key counts. Titles and bodies use upper case keys and
  /// Linear issue links; anything that isn't a real ticket is dropped after the lookup.
  static func ticketKeys(headRefName: String, title: String, body: String) -> [String] {
    var keys: [String] = []
    func add(_ key: String) { if !keys.contains(key) { keys.append(key) } }
    if let match = branchKey.firstMatch(in: headRefName, range: NSRange(headRefName.startIndex..., in: headRefName)) {
      add(String(headRefName[Range(match.range(at: 1), in: headRefName)!]).uppercased())
    }
    for match in titleKey.matches(in: title, range: NSRange(title.startIndex..., in: title)) {
      add(String(title[Range(match.range, in: title)!]))
    }
    for match in linearLink.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
      add(String(body[Range(match.range(at: 1), in: body)!]))
    }
    return keys
  }

  static func ticketKeys(_ pr: GithubPr) -> [String] {
    ticketKeys(headRefName: pr.headRefName, title: pr.title, body: pr.body)
  }

  struct MergeRules: Equatable {
    var approvals = 0
    var codeOwners = false
    /// Unresolved review threads block the merge.
    var threadResolution = false
    /// The branch must be up to date with its base before merging.
    var strictChecks = false
    /// Check names that must pass, whether or not they've reported yet.
    var requiredChecks: [String] = []
  }

  /// The rules that bind the PR's base branch. A ruleset that also restricts updates only lets its
  /// bypass actors merge, and they skip its rules, so none of its rules apply in practice.
  static func mergeRules(_ baseRef: GithubPr.BaseRef?) -> MergeRules {
    let rules = baseRef?.rules.nodes ?? []
    let restricted = Set(rules.filter { $0.type == "UPDATE" }.map { $0.repositoryRuleset?.id })
    let binding = rules.filter { !restricted.contains($0.repositoryRuleset?.id) }
    let pullRequestRules = binding.filter { $0.type == "PULL_REQUEST" }
    let protection = baseRef?.branchProtectionRule
    var required: [String] = []
    for name in (protection?.requiredStatusCheckContexts ?? [])
      + binding.flatMap({ $0.type == "REQUIRED_STATUS_CHECKS" ? ($0.parameters?.requiredStatusChecks ?? []).map(\.context) : [] })
      where !required.contains(name) {
      required.append(name)
    }
    return MergeRules(
      approvals: max(protection?.requiredApprovingReviewCount ?? 0, pullRequestRules.map { $0.parameters?.requiredApprovingReviewCount ?? 0 }.max() ?? 0),
      codeOwners: (protection?.requiresCodeOwnerReviews ?? false) || pullRequestRules.contains { $0.parameters?.requireCodeOwnerReview == true },
      threadResolution: (protection?.requiresConversationResolution ?? false)
        || pullRequestRules.contains { $0.parameters?.requiredReviewThreadResolution == true },
      strictChecks: (protection?.requiresStrictStatusChecks ?? false)
        || binding.contains { $0.type == "REQUIRED_STATUS_CHECKS" && $0.parameters?.strictRequiredStatusChecksPolicy == true },
      requiredChecks: required
    )
  }

  /// Every check on the head commit, each read the same way the summary reads it. A required check
  /// that hasn't reported yet (common right after a push) is listed as pending, because GitHub
  /// treats it as "expected" and won't merge without it.
  static func checks(commits: Nodes<GithubPr.Commit>, mergedAt: String?, baseRef: GithubPr.BaseRef?) -> [CheckItem] {
    let contexts = commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
    let requiredNames = mergedAt != nil ? [] : mergeRules(baseRef).requiredChecks
    // Without branch protection nothing is "required", so every check counts.
    let hasProtection = !requiredNames.isEmpty || contexts.contains(where: \.isRequired)
    let reported: [CheckItem] = contexts.compactMap { context in
      switch context {
      case let .checkRun(name, status, conclusion, url, isRequired):
        let state: CheckState =
          status != "COMPLETED" ? .pending
            : conclusion.map(failingConclusions.contains) == true ? .failed
            : conclusion.map(skippedConclusions.contains) == true ? .skipped
            : .passed
        return CheckItem(name: name, state: state, required: !hasProtection || isRequired, url: url)
      case let .statusContext(name, state, url, isRequired):
        let state: CheckState = state == "PENDING" || state == "EXPECTED" ? .pending : state == "FAILURE" || state == "ERROR" ? .failed : .passed
        return CheckItem(name: name, state: state, required: !hasProtection || isRequired, url: url)
      case .other:
        return nil
      }
    }
    let names = Set(reported.map(\.name))
    let expected = requiredNames.filter { !names.contains($0) }
      .map { CheckItem(name: $0, state: .pending, required: true, url: nil, expected: true) }
    return reported + expected
  }

  private static func summariseChecks(_ raw: GithubPr) -> CheckSummary {
    let checks = checks(commits: raw.commits, mergedAt: raw.mergedAt, baseRef: raw.baseRef)
    var summary = CheckSummary(total: checks.count)
    for check in checks {
      if check.state == .failed {
        let failed = FailedCheck(name: check.name, url: check.url)
        if check.required { summary.failing.append(failed) } else { summary.advisoryFailing.append(failed) }
      } else if check.state == .pending && check.required {
        summary.pending.append(check.name)
      }
    }
    summary.state = !summary.failing.isEmpty ? .failing : !summary.pending.isEmpty ? .pending : !checks.isEmpty ? .passing : .none
    return summary
  }

  static func isCodeRabbit(_ login: String?) -> Bool { login?.hasPrefix("coderabbitai") ?? false }

  private static func summariseCodeRabbit(_ raw: GithubPr) -> CodeRabbitSummary {
    let review = raw.latestOpinionatedReviews.nodes.first { isCodeRabbit($0.author?.login) }?.state
    return CodeRabbitSummary(
      review: review.flatMap(CodeRabbitSummary.Review.init(rawValue:)),
      unresolvedThreads: raw.reviewThreads.nodes.filter { !$0.isResolved && isCodeRabbit($0.comments.nodes.first?.author?.login) }.count
    )
  }

  /// What was gathered beyond the PR itself so code-owner review can be worked out.
  struct ReviewContext: Sendable {
    let codeowners: Codeowners?
    let files: [String]
    let filesComplete: Bool
    /// The org's teams keyed by lower-case "org/slug", for owners GitHub didn't request.
    let teams: [String: Person]
  }

  static func userPerson(_ actor: RawActor) -> Person {
    Person(kind: .user, id: actor.login, name: actor.login, avatarUrl: actor.avatarUrl, url: "https://github.com/\(actor.login)")
  }

  private static func reviewerPerson(_ reviewer: RawReviewer) -> Person? {
    switch reviewer {
    case .mannequin: nil
    case let .user(actor): userPerson(actor)
    case let .team(slug, name, avatarUrl, org):
      Person(kind: .team, id: "\(org)/\(slug)", name: name, avatarUrl: avatarUrl, url: "https://github.com/orgs/\(org)/teams/\(slug)")
    }
  }

  /// A CODEOWNERS entry ("@org/team" or "@login"), using the requested reviewer's details when there is one.
  private static func ownerPerson(_ owner: String, requested: [String: Person], teams: [String: Person]) -> Person {
    let id = String(owner.dropFirst())
    if let known = requested[id.lowercased()] ?? teams[id.lowercased()] { return known }
    let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
    if parts.count == 2 {
      return Person(kind: .team, id: id, name: parts[1], avatarUrl: nil, url: "https://github.com/orgs/\(parts[0])/teams/\(parts[1])")
    }
    return Person(kind: .user, id: id, name: id, avatarUrl: "https://github.com/\(id).png?size=48", url: "https://github.com/\(id)")
  }

  /// Who still has to approve before the PR can merge: one approval per code-owner group whose
  /// files are untouched by an approval so far, plus any approvals still short of the required
  /// count. Reviews made "on behalf of" a team clear that team; the author can't clear their own files.
  private static func reviewGate(_ raw: GithubPr, approvals: [Person], review: ReviewContext?) -> ReviewGate {
    let rules = mergeRules(raw.baseRef)
    let org = raw.repository.nameWithOwner.split(separator: "/").first.map { $0.lowercased() } ?? ""
    let author = raw.author?.login.lowercased()

    var requested: [String: Person] = [:]
    var requestedOrder: [String] = []
    for request in raw.reviewRequests.nodes {
      guard let reviewer = request.requestedReviewer, let person = reviewerPerson(reviewer), !isCodeRabbit(person.id) else { continue }
      let key = person.id.lowercased()
      if requested[key] == nil { requestedOrder.append(key) }
      requested[key] = person
    }

    var approvedBy = Set<String>()
    for review in raw.latestOpinionatedReviews.nodes where review.state == "APPROVED" {
      guard let login = review.author?.login, !isCodeRabbit(login) else { continue }
      approvedBy.insert(login.lowercased())
      for team in review.onBehalfOf.nodes { approvedBy.insert("\(org)/\(team.slug.lowercased())") }
    }

    var groups: [(key: String, people: [Person])] = []
    if rules.codeOwners, let review, let codeowners = review.codeowners {
      for file in review.files {
        let owners = codeowners.ownersOf(file).filter { $0.dropFirst().lowercased() != author }
        if owners.isEmpty || owners.contains(where: { approvedBy.contains($0.dropFirst().lowercased()) }) { continue }
        let key = owners.map { $0.lowercased() }.sorted().joined(separator: " ")
        if !groups.contains(where: { $0.key == key }) {
          groups.append((key, owners.map { ownerPerson($0, requested: requested, teams: review.teams) }))
        }
      }
    }

    let blocking = Set(groups.flatMap(\.people).map { $0.id.lowercased() })
    return ReviewGate(
      codeOwners: groups.map(\.people),
      approvalsNeeded: max(0, rules.approvals - approvals.count),
      optional: requestedOrder.compactMap { requested[$0] }.filter { !blocking.contains($0.id.lowercased()) },
      complete: !rules.codeOwners || (review?.codeowners != nil && review!.filesComplete)
    )
  }

  private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

  /// Ordered so the first thing the author has to act on wins.
  private static func status(
    _ raw: GithubPr, checks: CheckSummary, coderabbit: CodeRabbitSummary, unresolved: Int, changesRequested: Bool, gate: ReviewGate?
  ) -> (PrStatus, WaitingOn) {
    if raw.mergedAt != nil { return (PrStatus(label: "Merged", tone: .good), .merge) }
    if raw.isDraft { return (PrStatus(label: "Draft", tone: .neutral), .draft) }
    if raw.mergeStateStatus == "DIRTY" { return (PrStatus(label: "Merge conflicts", tone: .bad), .you) }
    if checks.state == .failing { return (PrStatus(label: "CI failing (\(checks.failing.count))", tone: .bad), .you) }
    // reviewDecision only reflects classic branch protection, so rulesets need the reviews themselves.
    if raw.reviewDecision == "CHANGES_REQUESTED" || changesRequested { return (PrStatus(label: "Changes requested", tone: .bad), .you) }
    if coderabbit.review == .changesRequested { return (PrStatus(label: "CodeRabbit wants changes", tone: .warn), .you) }
    if checks.state == .pending { return (PrStatus(label: "CI running (\(checks.pending.count))", tone: .neutral), .ci) }
    if unresolved > 0 { return (PrStatus(label: "\(plural(unresolved, "unresolved thread"))", tone: .warn), .you) }
    if raw.mergeStateStatus == "BEHIND" { return (PrStatus(label: "Behind base", tone: .warn), .you) }
    if let gate, !gate.codeOwners.isEmpty { return (PrStatus(label: "Needs code owner", tone: .neutral), .reviewer) }
    if let gate, gate.approvalsNeeded > 0 { return (PrStatus(label: "Needs \(plural(gate.approvalsNeeded, "approval"))", tone: .neutral), .reviewer) }
    // With the review rules read and nothing outstanding, BLOCKED just means "use the merge queue".
    if gate?.complete == true || raw.reviewDecision == "APPROVED" || ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(raw.mergeStateStatus) {
      return (PrStatus(label: "Ready to merge", tone: .good), .merge)
    }
    return (PrStatus(label: "Needs reviewer", tone: .neutral), .reviewer)
  }

  private static func mismatches(_ raw: GithubPr, tickets: [Ticket], ticketKeys: [String]) -> [Mismatch] {
    if ticketKeys.isEmpty { return [.noTicket] }
    if raw.mergedAt != nil {
      return tickets.contains { !closedTicketTypes.contains($0.stateType) } ? [.prMergedTicketOpen] : []
    }
    var mismatches: [Mismatch] = []
    if !tickets.isEmpty && tickets.allSatisfy({ closedTicketTypes.contains($0.stateType) }) { mismatches.append(.ticketClosedPrOpen) }
    if !raw.isDraft && tickets.contains(where: { notStartedTicketTypes.contains($0.stateType) }) { mismatches.append(.ticketNotStarted) }
    return mismatches
  }

  /// `ticketsByKey` is nil when Linear isn't configured: keys are then kept as they are instead of
  /// being filtered down to tickets that exist.
  static func pr(_ raw: GithubPr, tickets ticketsByKey: [String: Ticket]?, review: ReviewContext? = nil) -> Pr {
    let extracted = ticketKeys(raw)
    let keys = ticketsByKey.map { found in extracted.filter { found[$0] != nil } } ?? extracted
    let tickets = keys.compactMap { ticketsByKey?[$0] }

    let checks = summariseChecks(raw)
    let coderabbit = summariseCodeRabbit(raw)
    let unresolved = raw.reviewThreads.nodes.filter { !$0.isResolved }.count
    let humanReviews = raw.latestOpinionatedReviews.nodes.filter { !isCodeRabbit($0.author?.login) }
    func reviewers(_ state: String) -> [Person] {
      humanReviews.filter { $0.state == state }.compactMap { $0.author.map(userPerson) }
    }
    let approvals = reviewers("APPROVED")
    let changesRequestedBy = reviewers("CHANGES_REQUESTED")
    let gate = raw.mergedAt != nil ? nil : reviewGate(raw, approvals: approvals, review: review)
    let (status, waitingOn) = status(
      raw, checks: checks, coderabbit: coderabbit, unresolved: unresolved, changesRequested: !changesRequestedBy.isEmpty, gate: gate
    )

    return Pr(
      number: raw.number, title: raw.title, url: raw.url, repo: raw.repository.nameWithOwner,
      author: raw.author?.login ?? "ghost", authorAvatarUrl: raw.author?.avatarUrl, isDraft: raw.isDraft,
      headRef: raw.headRefName, baseRef: raw.baseRefName, createdAt: raw.createdAt, updatedAt: raw.updatedAt,
      mergedAt: raw.mergedAt, additions: raw.additions, deletions: raw.deletions, status: status, waitingOn: waitingOn,
      checks: checks, coderabbit: coderabbit, reviewDecision: raw.reviewDecision, approvals: approvals,
      changesRequestedBy: changesRequestedBy, reviewGate: gate, unresolvedThreads: unresolved, ticketKeys: keys,
      tickets: tickets, mismatches: mismatches(raw, tickets: tickets, ticketKeys: keys), stackedOn: nil
    )
  }

  /// Links each PR to the open PR in the same repo whose head branch it targets.
  static func linkStacks(_ prs: [Pr]) -> [Pr] {
    var byHead: [String: Int] = [:]
    for pr in prs { byHead["\(pr.repo):\(pr.headRef)"] = pr.number }
    return prs.map { pr in
      var linked = pr
      linked.stackedOn = byHead["\(pr.repo):\(pr.baseRef)"]
      return linked
    }
  }
}
