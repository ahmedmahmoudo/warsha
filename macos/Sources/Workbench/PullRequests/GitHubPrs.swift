import Foundation

// GitHub's side of the Pull Requests page: server/integrations/github.ts in Swift.

struct RawActor: Decodable, Sendable {
  let login: String
  let avatarUrl: String
}

enum RawCheckContext: Decodable, Sendable {
  case checkRun(name: String, status: String, conclusion: String?, detailsUrl: String?, isRequired: Bool)
  case statusContext(context: String, state: String, targetUrl: String?, isRequired: Bool)
  case other

  var isRequired: Bool {
    switch self {
    case let .checkRun(_, _, _, _, required), let .statusContext(_, _, _, required): required
    case .other: false
    }
  }

  private enum Keys: String, CodingKey {
    case __typename, name, status, conclusion, detailsUrl, isRequired, context, state, targetUrl
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let required = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
    switch try c.decodeIfPresent(String.self, forKey: .__typename) {
    case "CheckRun":
      self = try .checkRun(
        name: c.decode(String.self, forKey: .name), status: c.decode(String.self, forKey: .status),
        conclusion: c.decodeIfPresent(String.self, forKey: .conclusion), detailsUrl: c.decodeIfPresent(String.self, forKey: .detailsUrl),
        isRequired: required
      )
    case "StatusContext":
      self = try .statusContext(
        context: c.decode(String.self, forKey: .context), state: c.decode(String.self, forKey: .state),
        targetUrl: c.decodeIfPresent(String.self, forKey: .targetUrl), isRequired: required
      )
    default:
      self = .other
    }
  }
}

enum RawReviewer: Decodable, Sendable {
  case user(RawActor)
  case team(slug: String, name: String, avatarUrl: String?, org: String)
  case mannequin

  private enum Keys: String, CodingKey { case __typename, login, avatarUrl, slug, name, organization }
  private struct Org: Decodable { let login: String }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(String.self, forKey: .__typename) {
    case "User", "Bot":
      self = try .user(RawActor(login: c.decode(String.self, forKey: .login), avatarUrl: c.decode(String.self, forKey: .avatarUrl)))
    case "Team":
      self = try .team(
        slug: c.decode(String.self, forKey: .slug), name: c.decode(String.self, forKey: .name),
        avatarUrl: c.decodeIfPresent(String.self, forKey: .avatarUrl), org: c.decode(Org.self, forKey: .organization).login
      )
    default:
      self = .mannequin
    }
  }
}

struct RawRule: Decodable, Sendable {
  struct Parameters: Decodable, Sendable {
    struct Check: Decodable, Sendable { let context: String }
    let requiredApprovingReviewCount: Int?
    let requireCodeOwnerReview: Bool?
    let requiredReviewThreadResolution: Bool?
    let strictRequiredStatusChecksPolicy: Bool?
    let requiredStatusChecks: [Check]?
  }
  struct Ruleset: Decodable, Sendable { let id: String }
  let type: String
  let repositoryRuleset: Ruleset?
  let parameters: Parameters?
}

struct Nodes<T: Decodable & Sendable>: Decodable, Sendable {
  let nodes: [T]
}

struct PageInfo: Decodable, Sendable {
  let hasNextPage: Bool
  let endCursor: String?
}

struct GithubPr: Decodable, Sendable {
  struct Repository: Decodable, Sendable { let nameWithOwner: String }
  struct BaseRef: Decodable, Sendable {
    struct Protection: Decodable, Sendable {
      let requiredApprovingReviewCount: Int?
      let requiresCodeOwnerReviews: Bool
      let requiresConversationResolution: Bool
      let requiresStrictStatusChecks: Bool
      let requiredStatusCheckContexts: [String]
    }
    let rules: Nodes<RawRule>
    let branchProtectionRule: Protection?
  }
  struct Files: Decodable, Sendable {
    struct File: Decodable, Sendable { let path: String }
    let pageInfo: PageInfo
    let nodes: [File]
  }
  struct Commit: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
      struct Rollup: Decodable, Sendable { let state: String; let contexts: Nodes<RawCheckContext> }
      let statusCheckRollup: Rollup?
    }
    let commit: Inner
  }
  struct Thread: Decodable, Sendable {
    struct Comment: Decodable, Sendable { struct Author: Decodable, Sendable { let login: String }; let author: Author? }
    let isResolved: Bool
    let comments: Nodes<Comment>
    /// The thread's latest comment: whoever wrote it is waiting on the other side.
    let lastComment: Nodes<Comment>?
  }
  struct Review: Decodable, Sendable {
    struct Team: Decodable, Sendable { let slug: String }
    let state: String
    let author: RawActor?
    let onBehalfOf: Nodes<Team>
  }
  struct ReviewRequest: Decodable, Sendable {
    let asCodeOwner: Bool
    let requestedReviewer: RawReviewer?
  }

  let id: String
  let number: Int
  let title: String
  let url: String
  let body: String
  let isDraft: Bool
  let createdAt: String
  let updatedAt: String
  let mergedAt: String?
  let headRefName: String
  let baseRefName: String
  let additions: Int
  let deletions: Int
  let mergeStateStatus: String
  let reviewDecision: String?
  let author: RawActor?
  let repository: Repository
  /// Nil once the base branch is deleted.
  let baseRef: BaseRef?
  let files: Files
  let commits: Nodes<Commit>
  let reviewThreads: Nodes<Thread>
  let latestOpinionatedReviews: Nodes<Review>
  let reviewRequests: Nodes<ReviewRequest>
}

struct RawTeam: Decodable, Sendable {
  let slug: String
  let name: String
  let avatarUrl: String?
}

extension GitHub {
  private static let searchPageSize = 100
  private static let maxSearchPages = 3
  private static let detailChunk = 8
  /// GitHub's secondary rate limit drops heavy queries fired all at once.
  private static let detailConcurrency = 4

  /// The base branch's rules and the head commit's checks: everything a check list is read from.
  /// `isRequired` takes the PR number, so each PR gets its own selection with the number inlined.
  static func checkFields(_ number: Int) -> String {
    """
    mergedAt
    baseRef {
      rules(first: 30) { nodes { type repositoryRuleset { id } parameters {
        ... on PullRequestParameters { requiredApprovingReviewCount requireCodeOwnerReview requiredReviewThreadResolution }
        ... on RequiredStatusChecksParameters { strictRequiredStatusChecksPolicy requiredStatusChecks { context } }
      } } }
      branchProtectionRule {
        requiredApprovingReviewCount requiresCodeOwnerReviews requiresConversationResolution requiresStrictStatusChecks
        requiredStatusCheckContexts
      }
    }
    commits(last: 1) {
      nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { name status conclusion detailsUrl isRequired(pullRequestNumber: \(number)) }
        ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: \(number)) }
      } } } } }
    }
    """
  }

  /// The fields every PR needs, list or details page.
  static func prFields(_ number: Int) -> String {
    """
    id number title url body isDraft createdAt updatedAt mergedAt
    headRefName baseRefName additions deletions mergeStateStatus reviewDecision
    author { login avatarUrl(size: 48) }
    repository { nameWithOwner }
    \(checkFields(number))
    files(first: 100) { pageInfo { hasNextPage endCursor } nodes { path } }
    reviewThreads(first: 100) { nodes {
      isResolved comments(first: 1) { nodes { author { login } } } lastComment: comments(last: 1) { nodes { author { login } } }
    } }
    latestOpinionatedReviews(first: 20) { nodes {
      state author { login avatarUrl(size: 48) } onBehalfOf(first: 10) { nodes { slug } }
    } }
    reviewRequests(first: 20) { nodes { asCodeOwner requestedReviewer {
      __typename
      ... on User { login avatarUrl(size: 48) }
      ... on Bot { login avatarUrl(size: 48) }
      ... on Team { slug name avatarUrl(size: 48) organization { login } }
    } } }
    """
  }

  private struct PrRef: Decodable, Sendable {
    struct Commits: Decodable, Sendable {
      struct Node: Decodable, Sendable {
        struct Commit: Decodable, Sendable { struct Rollup: Decodable, Sendable { let state: String? }; let oid: String?; let statusCheckRollup: Rollup? }
        let commit: Commit?
      }
      let nodes: [Node]
    }
    let id: String?
    let number: Int?
    let updatedAt: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let commits: Commits?
  }

  /// Search is slow on GitHub's side and gets slower with every nested field, so it only returns
  /// ids; the details come from batched `node` lookups that run in parallel.
  /// A PR as search finds it: enough to tell whether it changed since its details were read.
  struct PrSearchRef: Sendable {
    let id: String
    let number: Int
    /// Changes when anything the list shows could have: an edit, a review or comment (updatedAt),
    /// a push (the head commit), CI finishing (its rollup), or the base moving (merge state).
    let fingerprint: String
  }

  /// The PRs a search matches, with their fingerprints. Costs one point per 100 PRs, where reading
  /// their details costs about two each, so a refresh only reads the details of what changed.
  static func searchPrRefs(_ query: String, token: String) async throws -> (refs: [PrSearchRef], truncated: Bool) {
    struct Search: Decodable { struct Inner: Decodable { let pageInfo: PageInfo; let nodes: [PrRef] }; let search: Inner }
    var refs: [PrSearchRef] = []
    var after: String?
    var truncated = true
    for _ in 0 ..< maxSearchPages {
      let page = try await graphql(
        """
        query SearchPrRefs($query: String!, $first: Int!, $after: String) {
          search(type: ISSUE, query: $query, first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest {
              id number updatedAt mergeStateStatus reviewDecision
              commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
            } }
          }
        }
        """,
        variables: ["query": query, "first": searchPageSize, "after": after ?? NSNull()],
        token: token, as: Search.self
      ).search
      refs += page.nodes.compactMap { ref in
        guard let id = ref.id, let number = ref.number else { return nil }
        let commit = ref.commits?.nodes.first?.commit
        let fingerprint = [ref.updatedAt, ref.mergeStateStatus, ref.reviewDecision, commit?.oid, commit?.statusCheckRollup?.state]
          .map { $0 ?? "-" }.joined(separator: "|")
        return PrSearchRef(id: id, number: number, fingerprint: fingerprint)
      }
      if !page.pageInfo.hasNextPage {
        truncated = false
        break
      }
      after = page.pageInfo.endCursor
    }
    return (refs, truncated)
  }

  /// Full details of PRs, read in parallel batches.
  static func prDetails(_ refs: [(id: String, number: Int)], token: String) async throws -> [GithubPr] {
    let chunks = stride(from: 0, to: refs.count, by: detailChunk).map { Array(refs[$0 ..< min($0 + detailChunk, refs.count)]) }
    return try await withThrowingTaskGroup(of: [GithubPr].self) { group in
      var prs: [GithubPr] = []
      var next = 0
      func addNext() {
        guard next < chunks.count else { return }
        let chunk = chunks[next]
        next += 1
        group.addTask {
          let definitions = chunk.indices.map { "$id\($0): ID!" }.joined(separator: ", ")
          let selections = chunk.enumerated().map { index, ref in
            "p\(index): node(id: $id\(index)) { ... on PullRequest { \(prFields(ref.number)) } }"
          }.joined(separator: "\n")
          var variables: [String: any Sendable] = [:]
          for (index, ref) in chunk.enumerated() { variables["id\(index)"] = ref.id }
          let result = try await graphql(
            "query PrDetails(\(definitions)) {\(selections)\n}", variables: variables, token: token, as: [String: GithubPr?].self
          )
          return result.values.compactMap { $0 }
        }
      }
      for _ in 0 ..< detailConcurrency { addNext() }
      while let batch = try await group.next() {
        prs += batch
        addNext()
      }
      return prs
    }
  }

  /// GitHub caps a PR's file list at 3,000.
  private static let maxFilePages = 30

  /// The rest of a PR's changed files, after the first page that came with its details.
  static func remainingFiles(prId: String, after: String, token: String) async throws -> [String] {
    struct Page: Decodable { struct Node: Decodable { let files: GithubPr.Files }; let node: Node }
    var paths: [String] = []
    var cursor: String? = after
    var page = 0
    while let current = cursor, page < maxFilePages {
      let files = try await graphql(
        """
        query PrFiles($id: ID!, $after: String) { node(id: $id) { ... on PullRequest {
          files(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { path } }
        } } }
        """,
        variables: ["id": prId, "after": current], token: token, as: Page.self
      ).node.files
      paths += files.nodes.map(\.path)
      cursor = files.pageInfo.hasNextPage ? files.pageInfo.endCursor : nil
      page += 1
    }
    return paths
  }

  private static let maxTeamPages = 5

  /// Every team in the org, for naming code owners that weren't requested. Needs read:org.
  static func orgTeams(_ org: String, token: String) async throws -> [RawTeam] {
    struct Page: Decodable {
      struct Org: Decodable { struct Teams: Decodable { let pageInfo: PageInfo; let nodes: [RawTeam] }; let teams: Teams }
      let organization: Org?
    }
    var teams: [RawTeam] = []
    var after: String?
    for _ in 0 ..< maxTeamPages {
      guard let organization = try await graphql(
        """
        query OrgTeams($org: String!, $after: String) { organization(login: $org) {
          teams(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { slug name avatarUrl(size: 48) } }
        } }
        """,
        variables: ["org": org, "after": after ?? NSNull()], token: token, as: Page.self
      ).organization else { break }
      teams += organization.teams.nodes
      guard organization.teams.pageInfo.hasNextPage else { break }
      after = organization.teams.pageInfo.endCursor
    }
    return teams
  }

  /// GitHub uses the first of these that exists on the base branch.
  private static let codeownersPaths = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]

  static func codeownersText(repo: String, branch: String, token: String) async throws -> String? {
    struct Blob: Decodable { let text: String? }
    struct Result: Decodable { let repository: [String: Blob?]? }
    let parts = repo.split(separator: "/").map(String.init)
    let selections = codeownersPaths.enumerated().map { index, path in
      "f\(index): object(expression: \(jsonString("\(branch):\(path)"))) { ... on Blob { text } }"
    }.joined(separator: "\n")
    let result = try await graphql(
      "query Codeowners($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {\n\(selections)\n} }",
      variables: ["owner": parts[0], "name": parts[1]], token: token, as: Result.self
    )
    return codeownersPaths.indices.lazy.compactMap { result.repository?["f\($0)"]??.text }.first
  }

  private static func jsonString(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
  }

  private static let expiryWarningDays = 7

  /// What the token can actually read. GitHub search quietly returns nothing for repos a token
  /// can't see, so without this a bad token just looks like "no PRs".
  static func tokenProblems(token: String, repos: [String]) async -> [String] {
    guard !token.isEmpty else { return [] }
    let fineGrained = token.hasPrefix("github_pat_")
    let parts = repos.map { repo in repo.split(separator: "/", maxSplits: 1).map(String.init) + ["", ""] }
    let definitions = parts.indices.flatMap { ["$owner\($0): String!", "$name\($0): String!"] }.joined(separator: ", ")
    let selections = parts.indices.map { index in
      """
      r\(index): repository(owner: $owner\(index), name: $name\(index)) {
        nameWithOwner
        pullRequests(first: 1, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes {
          number
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        } }
      }
      """
    }.joined(separator: "\n")
    var variables: [String: any Sendable] = [:]
    for (index, part) in parts.enumerated() {
      variables["owner\(index)"] = part[0]
      variables["name\(index)"] = part[1]
    }
    let query = "query TokenCheck\(definitions.isEmpty ? "" : "(\(definitions))") { viewer { login }\n\(selections)\n}"

    let result: RawResult<JSONValue>
    do {
      result = try await graphqlRaw(query, variables: variables, token: token, as: JSONValue.self)
    } catch {
      return [error.localizedDescription]
    }

    var problems: [String] = []
    if let scopes = result.headers["x-oauth-scopes"] {
      let granted = scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      if !granted.contains("repo") { problems.append("GitHub token is missing the \"repo\" scope") }
      if !granted.contains(where: { ["read:org", "write:org", "admin:org"].contains($0) }) {
        problems.append("GitHub token is missing the \"read:org\" scope")
      }
    }
    // Signed-in tokens (gho_, ghu_) are renewed by Workbench, so their expiry isn't news.
    let signedIn = token.hasPrefix("gho_") || token.hasPrefix("ghu_")
    if !signedIn, let expiry = result.headers["github-authentication-token-expiration"], let date = parseExpiry(expiry) {
      let daysLeft = Int(floor(date.timeIntervalSinceNow / 86_400))
      if daysLeft < expiryWarningDays { problems.append("GitHub token expires in \(max(daysLeft, 0)) days (\(expiry))") }
    }
    for (index, repo) in repos.enumerated() {
      guard let error = result.errors.first(where: { $0.path?.first == "r\(index)" }) else { continue }
      let path = error.path?.joined(separator: ".") ?? ""
      if let restricted = oauthRestriction(error.message) {
        if !problems.contains(restricted) { problems.append(restricted) }
        continue
      }
      problems.append(
        path.contains("statusCheckRollup") ? "GitHub token can't read CI checks on \(repo): add Commit statuses (read) and Actions (read)"
          : path.contains("pullRequests") ? "GitHub token can't read pull requests on \(repo): add Pull requests (read)"
          : fineGrained
          ? "GitHub token can't see \(repo): set the token's resource owner to \(repo.split(separator: "/").first ?? ""), select the repo, and check the org approved the token"
          : "GitHub token can't see \(repo) (\(error.type ?? error.message)): check the repo name and the token's access"
      )
    }
    for error in result.errors where !(error.path?.first?.hasPrefix("r") ?? false) {
      problems.append("GitHub token check failed: \(error.formatted)")
    }
    return problems
  }

  /// An organization that hasn't approved Workbench's GitHub app yet blocks everything in it for
  /// signed-in tokens, which a pasted token isn't subject to.
  static func oauthRestriction(_ message: String) -> String? {
    guard message.contains("OAuth App access restrictions") else { return nil }
    let org = message.firstMatch(of: /`([^`]+)` organization/).map { String($0.1) } ?? "The organization"
    return "\(org) hasn't approved Workbench's GitHub sign-in yet, so its repos are hidden. Ask an org owner to approve it, or use a token instead."
  }

  /// "2026-11-01 00:00:00 UTC", as GitHub sends it.
  private static func parseExpiry(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    return formatter.date(from: text)
  }
}

/// Any JSON, for queries whose data is only checked for errors.
struct JSONValue: Decodable, Sendable {
  init(from decoder: any Decoder) throws {}
}
