import Foundation

// What the Pull Requests page shows: shared/prs.ts in Swift.

enum PrScope: String, CaseIterable, Identifiable, Sendable {
  case mine, reviewing, team
  var id: Self { self }
  var label: String {
    switch self {
    case .mine: "Mine"
    case .reviewing: "Reviewing"
    case .team: "Team"
    }
  }
}

struct Ticket: Equatable, Sendable {
  let key: String
  let title: String
  let url: String
  let state: String
  /// Linear's workflow category: backlog | unstarted | started | completed | canceled | triage
  let stateType: String
  let stateColor: String
  let assignee: String?
  let project: String?
}

struct FailedCheck: Equatable, Sendable {
  let name: String
  let url: String?
}

/// `state`, `failing` and `pending` cover required checks only; advisory failures are listed apart.
struct CheckSummary: Equatable, Sendable {
  enum State: Sendable { case passing, failing, pending, none }
  var state: State = .none
  var failing: [FailedCheck] = []
  var pending: [String] = []
  var advisoryFailing: [FailedCheck] = []
  var total = 0
}

enum CheckState: Sendable { case passed, failed, pending, skipped }

/// One check on the head commit.
struct CheckItem: Equatable, Sendable {
  let name: String
  let state: CheckState
  let required: Bool
  let url: String?
  /// Required by the branch rules but not reported yet.
  var expected = false
}

struct CodeRabbitSummary: Equatable, Sendable {
  enum Review: String, Sendable { case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", commented = "COMMENTED" }
  /// The bot's standing review, which outlives follow-up commits until it re-reviews.
  let review: Review?
  let unresolvedThreads: Int
}

/// A GitHub user or team, ready to show. `id` is a login, or "org/slug" for a team.
struct Person: Equatable, Hashable, Sendable {
  enum Kind: Sendable { case user, team }
  let kind: Kind
  let id: String
  let name: String
  let avatarUrl: String?
  let url: String
}

/// What review still stands between an open PR and merging, per the base branch's rules.
struct ReviewGate: Equatable, Sendable {
  /// Code-owner groups still missing an approval; one approval from anyone in a group clears it.
  let codeOwners: [[Person]]
  /// Approvals still needed from anyone, beyond the code owners.
  let approvalsNeeded: Int
  /// Requested reviewers whose approval isn't required to merge.
  let optional: [Person]
  /// False when not every changed file could be read, so `codeOwners` may be missing some.
  let complete: Bool
}

/// Who the PR is waiting on right now.
enum WaitingOn: CaseIterable, Sendable {
  case you, merge, ci, reviewer, draft
}

enum Mismatch: Sendable {
  case noTicket, ticketClosedPrOpen, ticketNotStarted, prMergedTicketOpen

  var label: String {
    switch self {
    case .noTicket: "No Linear ticket"
    case .ticketClosedPrOpen: "Ticket closed, PR still open"
    case .ticketNotStarted: "Ticket not started"
    case .prMergedTicketOpen: "Merged, ticket still open"
    }
  }
}

enum Tone: Sendable { case good, bad, warn, info, neutral }

struct PrStatus: Equatable, Sendable {
  let label: String
  let tone: Tone
}

struct Pr: Equatable, Identifiable, Sendable {
  var id: String { url }
  let number: Int
  let title: String
  let url: String
  let repo: String
  let author: String
  let authorAvatarUrl: String?
  let isDraft: Bool
  let headRef: String
  let baseRef: String
  let createdAt: String
  let updatedAt: String
  let mergedAt: String?
  let additions: Int
  let deletions: Int
  /// Plain-words reading of mergeStateStatus + checks + reviews.
  let status: PrStatus
  let waitingOn: WaitingOn
  let checks: CheckSummary
  let coderabbit: CodeRabbitSummary
  let reviewDecision: String?
  let approvals: [Person]
  let changesRequestedBy: [Person]
  /// Nil for merged PRs.
  let reviewGate: ReviewGate?
  let unresolvedThreads: Int
  /// Unresolved threads whose latest comment isn't the author's: someone is waiting on a reply.
  let threadsToReply: Int
  let ticketKeys: [String]
  let tickets: [Ticket]
  let mismatches: [Mismatch]
  /// Number of the open PR whose head this PR is stacked on, if any.
  var stackedOn: Int?
}

struct PrsResponse: Sendable {
  let scope: PrScope
  let viewer: String
  let open: [Pr]
  let recentlyMerged: [Pr]
  let fetchedAt: Date
  let warnings: [String]
}
