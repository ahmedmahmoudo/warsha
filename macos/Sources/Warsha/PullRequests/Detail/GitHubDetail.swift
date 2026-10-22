import Foundation

// GitHub's side of the PR details page: the detail queries in server/integrations/github.ts.

/// An actor on the details page, where bots are told apart from people.
struct RawDetailActor: Decodable, Sendable {
  let __typename: String
  let login: String
  let avatarUrl: String

  var actor: RawActor { RawActor(login: login, avatarUrl: avatarUrl) }
}

struct RawThread: Decodable, Sendable {
  struct Comments: Decodable, Sendable {
    struct Comment: Decodable, Sendable {
      let bodyText: String
      let url: String
      let createdAt: String
      let author: RawDetailActor?
    }
    let totalCount: Int
    let nodes: [Comment]
  }
  let id: String
  let isResolved: Bool
  let isOutdated: Bool
  let path: String
  let line: Int?
  let comments: Comments
  /// Who wrote the latest comment, to tell a thread waiting on a reply from one already answered.
  let lastComment: Nodes<GithubPr.Thread.Comment>?
}

struct RawReview: Decodable, Sendable {
  let id: String
  let state: String
  let bodyText: String
  let url: String
  let submittedAt: String?
  let author: RawDetailActor?
}

/// One of the timeline item types asked for below; only the fields of its type are set.
struct RawTimelineItem: Decodable, Sendable {
  struct Reviewer: Decodable, Sendable { let login: String?; let name: String? }
  struct Commit: Decodable, Sendable {
    struct Author: Decodable, Sendable { let user: RawActor?; let name: String? }
    let committedDate: String
    let messageHeadline: String
    let author: Author?
  }
  let __typename: String
  let id: String?
  let createdAt: String?
  let url: String?
  let actor: RawDetailActor?
  let author: RawDetailActor?
  let bodyText: String?
  let state: String?
  let reason: String?
  let dismissalMessage: String?
  let previousRefName: String?
  let currentRefName: String?
  let requestedReviewer: Reviewer?
  let commit: Commit?
}

struct GithubPrDetail: Decodable, Sendable {
  struct Queue: Decodable, Sendable { let state: String; let position: Int?; let enqueuedAt: String }

  /// The fields the list reads too.
  let base: GithubPr
  let state: String
  let closedAt: String?
  let headRefOid: String
  let mergeable: String
  let viewerCanUpdateBranch: Bool
  let body: String
  let bodyHTML: String
  let mergeQueueEntry: Queue?
  let threads: Nodes<RawThread>
  let reviews: Nodes<RawReview>
  let timelineItems: Nodes<RawTimelineItem>

  private enum Keys: String, CodingKey {
    case state, closedAt, headRefOid, mergeable, viewerCanUpdateBranch, body, bodyHTML, mergeQueueEntry, threads, reviews, timelineItems
  }

  init(from decoder: any Decoder) throws {
    base = try GithubPr(from: decoder)
    let c = try decoder.container(keyedBy: Keys.self)
    state = try c.decode(String.self, forKey: .state)
    closedAt = try c.decodeIfPresent(String.self, forKey: .closedAt)
    headRefOid = try c.decode(String.self, forKey: .headRefOid)
    mergeable = try c.decode(String.self, forKey: .mergeable)
    viewerCanUpdateBranch = try c.decode(Bool.self, forKey: .viewerCanUpdateBranch)
    body = try c.decode(String.self, forKey: .body)
    bodyHTML = try c.decode(String.self, forKey: .bodyHTML)
    mergeQueueEntry = try c.decodeIfPresent(Queue.self, forKey: .mergeQueueEntry)
    threads = try c.decode(Nodes<RawThread>.self, forKey: .threads)
    reviews = try c.decode(Nodes<RawReview>.self, forKey: .reviews)
    timelineItems = try c.decode(Nodes<RawTimelineItem>.self, forKey: .timelineItems)
  }
}

/// What the check list is read from, polled while CI runs.
struct GithubPrChecks: Decodable, Sendable {
  let headRefOid: String
  let mergedAt: String?
  let baseRef: GithubPr.BaseRef?
  let commits: Nodes<GithubPr.Commit>
}

extension GitHub {
  private static let detailActor = "{ __typename login avatarUrl(size: 48) }"

  private static let detailFields = """
    state closedAt bodyHTML headRefOid mergeable viewerCanUpdateBranch
    mergeQueueEntry { state position enqueuedAt }
    threads: reviewThreads(first: 100) { nodes {
      id isResolved isOutdated path line
      comments(first: 1) { totalCount nodes { bodyText url createdAt author \(detailActor) } }
      lastComment: comments(last: 1) { nodes { author { login } } }
    } }
    reviews: latestOpinionatedReviews(first: 20) { nodes { id state bodyText url submittedAt author \(detailActor) } }
    timelineItems(last: 100, itemTypes: [
      PULL_REQUEST_COMMIT, PULL_REQUEST_REVIEW, ISSUE_COMMENT, REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT,
      CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT,
      REMOVED_FROM_MERGE_QUEUE_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, REVIEW_DISMISSED_EVENT, BASE_REF_CHANGED_EVENT
    ]) { nodes {
      __typename
      ... on PullRequestCommit { id url commit {
        committedDate messageHeadline author { name user { login avatarUrl(size: 48) } }
      } }
      ... on PullRequestReview { id createdAt url state bodyText author \(detailActor) }
      ... on IssueComment { id createdAt url bodyText author \(detailActor) }
      ... on ReviewRequestedEvent { id createdAt actor \(detailActor) requestedReviewer {
        ... on User { login } ... on Bot { login } ... on Team { name }
      } }
      ... on ReadyForReviewEvent { id createdAt actor \(detailActor) }
      ... on ConvertToDraftEvent { id createdAt actor \(detailActor) }
      ... on MergedEvent { id createdAt actor \(detailActor) }
      ... on ClosedEvent { id createdAt actor \(detailActor) }
      ... on ReopenedEvent { id createdAt actor \(detailActor) }
      ... on AddedToMergeQueueEvent { id createdAt actor \(detailActor) }
      ... on RemovedFromMergeQueueEvent { id createdAt reason actor \(detailActor) }
      ... on HeadRefForcePushedEvent { id createdAt actor \(detailActor) }
      ... on ReviewDismissedEvent { id createdAt dismissalMessage actor \(detailActor) }
      ... on BaseRefChangedEvent { id createdAt previousRefName currentRefName actor \(detailActor) }
    } }
    """

  /// One PR with everything the details page shows; nil when it doesn't exist or isn't visible.
  static func prDetail(_ key: PrKey, token: String) async throws -> GithubPrDetail? {
    struct Result: Decodable { struct Repo: Decodable { let pullRequest: GithubPrDetail? }; let repository: Repo? }
    return try await graphql(
      """
      query PrDetail($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
        pullRequest(number: \(key.number)) { \(prFields(key.number)) \(detailFields) }
      } }
      """,
      variables: ["owner": key.owner, "name": key.name], token: token, as: Result.self
    ).repository?.pullRequest
  }

  /// Only what the check list needs, so the page can poll it while CI runs.
  static func prChecks(_ key: PrKey, token: String) async throws -> GithubPrChecks? {
    struct Result: Decodable { struct Repo: Decodable { let pullRequest: GithubPrChecks? }; let repository: Repo? }
    return try await graphql(
      """
      query PrChecks($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
        pullRequest(number: \(key.number)) { headRefOid \(checkFields(key.number)) }
      } }
      """,
      variables: ["owner": key.owner, "name": key.name], token: token, as: Result.self
    ).repository?.pullRequest
  }

  /// Just the PR's head commit, cheap enough to poll.
  static func prHeadOid(_ key: PrKey, token: String) async throws -> String? {
    struct Result: Decodable {
      struct Repo: Decodable { struct Pull: Decodable { let headRefOid: String }; let pullRequest: Pull? }
      let repository: Repo?
    }
    return try await graphql(
      """
      query Head($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefOid } }
      }
      """,
      variables: ["owner": key.owner, "name": key.name, "number": key.number], token: token, as: Result.self
    ).repository?.pullRequest?.headRefOid
  }

  /// How far the PR branch has drifted from its base: `behindBy` counts base commits the branch
  /// doesn't have yet. GitHub only reports BEHIND when the base requires an up-to-date branch, so
  /// the comparison is asked for directly.
  static func branchComparison(repo: String, base: String, head: String, token: String) async throws -> (aheadBy: Int, behindBy: Int)? {
    struct Result: Decodable {
      struct Repo: Decodable {
        struct Ref: Decodable { struct Compare: Decodable { let aheadBy: Int; let behindBy: Int }; let compare: Compare? }
        let ref: Ref?
      }
      let repository: Repo?
    }
    let parts = repo.split(separator: "/").map(String.init)
    let compare = try await graphql(
      """
      query Compare($owner: String!, $name: String!, $base: String!, $head: String!) {
        repository(owner: $owner, name: $name) { ref(qualifiedName: $base) { compare(headRef: $head) { aheadBy behindBy } } }
      }
      """,
      variables: ["owner": parts[0], "name": parts[1], "base": "refs/heads/\(base)", "head": head], token: token, as: Result.self
    ).repository?.ref?.compare
    return compare.map { ($0.aheadBy, $0.behindBy) }
  }

  /// GitHub's "Update branch": merges the base into the PR branch on GitHub. `expectedHeadOid`
  /// makes it fail rather than merge into commits the page hasn't shown.
  static func updatePullRequestBranch(id: String, expectedHeadOid: String, token: String) async throws {
    _ = try await graphql(
      """
      mutation UpdateBranch($id: ID!, $oid: GitObjectID!) {
        updatePullRequestBranch(input: { pullRequestId: $id, expectedHeadOid: $oid, updateMethod: MERGE }) {
          pullRequest { id }
        }
      }
      """,
      variables: ["id": id, "oid": expectedHeadOid], token: token, as: JSONValue.self
    )
  }
}

/// Files attached to a private repo's releases (often a draft release that hosts PR screenshots)
/// need the token, which an image view can't send. They're found among the repo's release assets
/// and downloaded through the API. server/images/route.ts in Swift.
actor ReleaseImages {
  static let shared = ReleaseImages()

  private static var releaseDownload: Regex<(Substring, Substring, Substring)> {
    #/^https://github\.com/([\w.-]+)/([\w.-]+)/releases/download/[^/]+/[^/]+$/#
  }
  private static let maxBytes = 10 * 1024 * 1024
  private static let maxPages = 20
  private static let rescanAfter: TimeInterval = 60

  private struct Index {
    var byUrl: [String: Int] = [:]
    var nextPage = 1
    var complete = false
    var scannedAt = Date.distantPast
  }

  private var indexes: [String: Index] = [:]

  static func needsToken(_ url: String) -> Bool { url.wholeMatch(of: releaseDownload) != nil }

  func data(for url: String, token: String) async throws -> Data {
    guard let match = url.wholeMatch(of: Self.releaseDownload) else { throw IntegrationError("Not a release download") }
    let repo = "\(match.1)/\(match.2)"
    guard let id = try await assetId(repo: repo, url: url, token: token) else {
      throw IntegrationError("That file isn't among \(repo)'s release assets")
    }
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(id)")!)
    request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.maxBytes else {
      throw IntegrationError("GitHub wouldn't send that file")
    }
    return data
  }

  /// Release assets are read a page at a time and only as far as needed; once every page is read,
  /// a miss starts over at most every minute (new uploads land on page one).
  private func assetId(repo: String, url: String, token: String) async throws -> Int? {
    var index = indexes[repo] ?? Index()
    if let id = index.byUrl[url] { return id }
    if index.complete {
      guard -index.scannedAt.timeIntervalSinceNow > Self.rescanAfter else { return nil }
      index = Index()
    }
    struct Release: Decodable { struct Asset: Decodable { let id: Int; let browser_download_url: String }; let assets: [Asset] }
    while index.byUrl[url] == nil && !index.complete {
      var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100&page=\(index.nextPage)")!)
      request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
      let (data, _) = try await URLSession.shared.data(for: request)
      let releases = (try? JSONDecoder().decode([Release].self, from: data)) ?? []
      for asset in releases.flatMap(\.assets) { index.byUrl[asset.browser_download_url] = asset.id }
      index.nextPage += 1
      if releases.count < 100 || index.nextPage > Self.maxPages { index.complete = true }
    }
    index.scannedAt = Date()
    indexes[repo] = index
    return index.byUrl[url]
  }
}
