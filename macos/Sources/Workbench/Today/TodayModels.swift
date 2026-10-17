import Foundation

// What the Today page shows: shared/today.ts in Swift.

/// A ticket assigned to you and not finished, with what decides how urgent it is.
struct OpenTicket: Equatable, Sendable {
  struct ProjectInfo: Equatable, Sendable {
    let name: String
    let url: String
    let targetDate: String?
    let statusType: String?
  }
  struct Cycle: Equatable, Sendable {
    let number: Int
    let startsAt: String
    let endsAt: String
  }

  let ticket: Ticket
  /// 0 none, 1 urgent, 2 high, 3 medium, 4 low (Linear's scale).
  let priority: Int
  let priorityLabel: String
  let labels: [String]
  let createdAt: String
  /// The latest time it was assigned to you.
  var assignedAt: String?
  let projectInfo: ProjectInfo?
  let cycle: Cycle?

  var key: String { ticket.key }
}

enum NeedsYouKind: String, CaseIterable, Sendable {
  case conflicts, ciFailing = "ci-failing", changesRequested = "changes-requested", stuckReview = "stuck-review"
  case threads, behind, slowReview = "slow-review", ready, mergedNotDone = "merged-not-done"
  /// A PR opened recently that nobody has reviewed yet: send it to the team.
  case sendForReview = "send-for-review"
}

/// A code owner (team or person) a review waits on; a team lists its members, minus you and the author.
struct NudgeTarget: Equatable, Sendable {
  let owner: Person
  let members: [Person]
}

/// Where an item's one action goes: a PR's details here, or a page in the browser.
enum ItemAction: Equatable, Sendable {
  case details(PrKey)
  case web(URL)
}

/// Something waiting on you, with why and the one thing to do about it.
struct NeedsYouItem: Equatable, Identifiable, Sendable {
  let id: String
  let kind: NeedsYouKind
  let tone: Tone
  /// What's wrong, short: "Merge conflicts", "CI failing".
  let title: String
  /// The specifics: failing checks, who it waits on, how long.
  let detail: String?
  let ticket: Ticket?
  let pr: Pr?
  let actionLabel: String
  let action: ItemAction
  /// What pins and notes attach to: the ticket when there is one, else the PR.
  let ref: Ref
  /// For a review that's stuck or slow: whose approval it waits on. Each inner list is one approval
  /// needed, from any one of its owners; teams list their members.
  var nudge: [[NudgeTarget]]?
}

struct UpNextItem: Equatable, Sendable {
  let ticket: OpenTicket
  let score: Int
  /// Why it ranks where it does: "Urgent", "Release Blocker", "Cycle ends in 3 days".
  let reasons: [String]
}

enum InboxKind: String, Sendable {
  case assigned, comment, mention, status, priority, project, other
}

/// Something that happened in Linear that concerns you, from your Linear inbox.
struct InboxItem: Equatable, Identifiable, Sendable {
  struct Actor: Equatable, Sendable { let name: String; let avatarUrl: String? }
  struct TicketSummary: Equatable, Sendable { let key: String; let title: String; let url: String; let state: String; let stateColor: String }
  struct Project: Equatable, Sendable { let name: String; let url: String }

  let id: String
  let kind: InboxKind
  let at: String
  /// Unread in Linear itself.
  let unread: Bool
  let actor: Actor?
  /// "assigned you", "commented on", "mentioned you on".
  let verb: String
  let ticket: TicketSummary?
  let project: Project?
  /// A comment's or update's first words.
  let snippet: String?
  let url: String?
}

struct Deadline: Equatable, Sendable {
  enum Kind: String, Sendable { case cycle, project }
  let kind: Kind
  let name: String
  let url: String?
  /// YYYY-MM-DD.
  let date: String
  let daysLeft: Int
  let ticketCount: Int
}

struct TodayData: Sendable {
  let viewer: String
  let timeZone: String
  let needsYou: [NeedsYouItem]
  let upNext: [UpNextItem]
  /// All open tickets assigned to you; the page picks out what's new since you last looked.
  let tickets: [OpenTicket]
  /// Open PRs asking for your review personally.
  let reviewRequests: [Pr]
  /// Your Linear inbox from the last couple of weeks, newest first.
  let inbox: [InboxItem]
  let deadlines: [Deadline]
  /// Your open PRs with nothing for you to do: CI running, or waiting on reviewers in good time.
  let waiting: [Pr]
  let warnings: [String]
  let fetchedAt: Date
}

/// How long a ticket has sat in its in-flight status, and whether that's too long.
struct TicketAge: Equatable, Sendable {
  enum Level: String, Sendable { case ok, warn, alert }
  let state: String
  let since: String
  let workingDays: Int
  let level: Level
  let message: String?
}
