import Foundation

// What the PR details page shows: shared/prDetail.ts in Swift.

/// A PR on GitHub: "owner/repo" and its number.
struct PrKey: Hashable, Sendable {
  let repo: String
  let number: Int

  init(repo: String, number: Int) {
    self.repo = repo
    self.number = number
  }

  init(_ pr: Pr) { self.init(repo: pr.repo, number: pr.number) }

  var owner: String { String(repo.split(separator: "/").first ?? "") }
  var name: String { String(repo.split(separator: "/").last ?? "") }
  var url: String { "https://github.com/\(repo)/pull/\(number)" }
}

/// The badge in the page header.
enum PrState: Sendable {
  case draft, open, ready, queued, merged, closed
}

/// Something that stops the PR merging right now, in the order the author should deal with it.
struct MergeBlocker: Equatable, Sendable {
  enum Kind: String, Sendable {
    case draft, conflicts, behind, ciFailing = "ci-failing", ciPending = "ci-pending"
    case changesRequested = "changes-requested", codeOwners = "code-owners", approvals, threads
  }
  let kind: Kind
  let label: String
  /// Names behind the label: checks, reviewers, owner groups.
  let items: [String]
}

struct MergeQueue: Equatable, Sendable {
  let position: Int?
  let state: String
  let enqueuedAt: String
}

struct MergeReadiness: Equatable, Sendable {
  /// False once merged or closed; the blockers are then empty.
  var applicable = false
  var ready = false
  /// Set while the PR sits in the merge queue.
  var queue: MergeQueue?
  var blockers: [MergeBlocker] = []
  /// Worth knowing but not stopping the merge: advisory CI, CodeRabbit, an out-of-date branch.
  var notes: [String] = []
}

struct ActivityItem: Equatable, Identifiable, Sendable {
  enum Kind: String, Sendable {
    case opened, commits, approved, changesRequested = "changes-requested", reviewed, comment
    case reviewRequested = "review-requested", event
  }
  let id: String
  let kind: Kind
  var at: String
  let actor: Person?
  let isBot: Bool
  /// What happened, without the actor: "pushed 3 commits", "added this to the merge queue".
  var title: String
  /// Plain-text excerpt: commit headlines, a review or comment body.
  var body: String?
  let url: String?
}

struct ReviewThread: Equatable, Identifiable, Sendable {
  let id: String
  let path: String
  let line: Int?
  let author: Person?
  let isBot: Bool
  let isOutdated: Bool
  /// The opening comment as plain text.
  let body: String
  let replies: Int
  let url: String
  let createdAt: String
  /// The PR's author wrote the latest comment, so it's the reviewer's turn.
  var replied = false
}

/// A reviewer whose latest review asks for changes, with what they asked for.
struct ChangeRequest: Equatable, Sendable {
  let reviewer: Person
  let at: String
  let body: String
  let url: String
  /// Their unresolved threads; also listed in `openThreads`.
  let threadIds: [String]
}

struct ActivitySummary: Equatable, Sendable {
  let commits: Int
  let approvals: Int
  let changeRequests: Int
  let comments: Int
  let botComments: Int
  let lastActivityAt: String
}

/// Things the page can do about the PR's branch; each is nil when it doesn't apply.
struct PrActions: Equatable, Sendable {
  struct Conflicts: Equatable, Sendable {
    enum Kind: Sendable { case worktree, newWorktree }
    let prompt: String
    /// The checkout Claude would run in, or nil when no local clone of the repo was found.
    let checkout: (path: String, kind: Kind)?
    /// One line to paste into a terminal; nil without a local checkout.
    let command: String?

    static func == (a: Self, b: Self) -> Bool {
      a.prompt == b.prompt && a.checkout?.path == b.checkout?.path && a.command == b.command
    }
  }

  struct UpdateBranch: Equatable, Sendable {
    let behindBy: Int
    let base: String
    /// False when GitHub won't do it here: conflicts, or no permission.
    let canUpdate: Bool
    let reason: String?
    let headOid: String
  }

  /// The branch conflicts with its base: hand it to Claude in a local checkout.
  var conflicts: Conflicts?
  /// The branch is missing commits from its base.
  var updateBranch: UpdateBranch?
}

/// An image from the description, shown in the gallery rather than in the text.
struct GalleryImage: Equatable, Identifiable, Sendable {
  var id: String { src }
  /// What to load: GitHub's (signed, short-lived) link, or a release download that needs the token.
  let src: String
  /// Where the image lives on GitHub, for "open original".
  let original: String
  let caption: String
}

struct PrDetail: Sendable {
  let pr: Pr
  let state: PrState
  /// The head commit everything here was read from.
  let headOid: String
  /// The description as GitHub-flavoured Markdown.
  let body: String
  let images: [GalleryImage]
  let closedAt: String?
  let checks: [CheckItem]
  let merge: MergeReadiness
  let activity: [ActivityItem]
  let activitySummary: ActivitySummary
  let openThreads: [ReviewThread]
  let changeRequests: [ChangeRequest]
  let actions: PrActions
  let fetchedAt: Date
}

/// Just the checks, polled while CI runs.
struct PrChecks: Sendable {
  let headOid: String
  let checks: [CheckItem]
  let fetchedAt: Date
}
