import Foundation

// GitHub and Linear queries for Activity: from server/integrations/github.ts and linear.ts.

struct RawActivityReview: Decodable, Sendable {
  struct Count: Decodable, Sendable { let totalCount: Int }
  let state: String
  let submittedAt: String?
  let url: String
  let comments: Count
}

struct RawActivityPr: Decodable, Sendable {
  struct Repository: Decodable, Sendable { let nameWithOwner: String }
  let number: Int
  let title: String
  let url: String
  let state: ActivityPr.State
  let isDraft: Bool
  let createdAt: String
  let mergedAt: String?
  let headRefName: String
  let body: String
  let repository: Repository
  let author: RawActor?
  /// The reviews the viewer left on it, from searches that ask for them.
  let reviews: Nodes<RawActivityReview>?
}

/// One of your events from GitHub's events feed.
struct RawGitHubEvent: Decodable, Sendable {
  struct Repo: Decodable, Sendable { let name: String }
  struct Payload: Decodable, Sendable {
    struct Numbered: Decodable, Sendable { let number: Int }
    struct Review: Decodable, Sendable { let state: String?; let html_url: String? }
    struct Comment: Decodable, Sendable { let html_url: String? }
    struct Issue: Decodable, Sendable {
      let number: Int
      let pull_request: JSONValue?
    }
    let action: String?
    let ref: String?
    let number: Int?
    let pull_request: Numbered?
    let review: Review?
    let comment: Comment?
    let issue: Issue?
  }
  let id: String
  let type: String
  let created_at: String
  let repo: Repo
  let payload: Payload
}

extension GitHub {
  private static let activityPrFields = """
    number title url state isDraft createdAt mergedAt headRefName body
    repository { nameWithOwner }
    author { login avatarUrl(size: 48) }
    """
  private static let activitySearchPages = 3

  /// PRs matching a search, each with the reviews `login` left on it.
  static func searchActivityPrs(_ query: String, login: String, token: String) async throws -> [RawActivityPr] {
    var prs: [RawActivityPr] = []
    var after: String?
    for _ in 0 ..< activitySearchPages {
      let search = try await graphql(
        """
        query ActivitySearch($q: String!, $after: String, $login: String!) {
          search(type: ISSUE, query: $q, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { \(activityPrFields)
              reviews(author: $login, first: 30) { nodes { state submittedAt url comments { totalCount } } }
            } }
          }
        }
        """,
        variables: ["q": query, "after": after ?? NSNull(), "login": login], token: token, as: OptionalNodes.self
      ).search
      prs += search.nodes.compactMap { $0 }
      guard search.pageInfo.hasNextPage else { break }
      after = search.pageInfo.endCursor
    }
    return prs
  }

  /// A search page whose non-PR nodes (empty objects) decode as nil.
  private struct OptionalNodes: Decodable {
    struct Search: Decodable {
      let pageInfo: PageInfo
      let nodes: [RawActivityPr?]

      private enum Keys: String, CodingKey { case pageInfo, nodes }
      init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pageInfo = try c.decode(PageInfo.self, forKey: .pageInfo)
        var list = try c.nestedUnkeyedContainer(forKey: .nodes)
        var nodes: [RawActivityPr?] = []
        while !list.isAtEnd { nodes.append(try? list.decode(RawActivityPr.self)) }
        self.nodes = nodes
      }
    }
    let search: Search
  }

  private static let prLookupChunk = 25

  /// Titles, authors and states for PRs the events feed only names by number. A PR in a repo the
  /// token can't see comes back as an error for its field; the rest still count.
  static func prsByNumber(_ refs: [(repo: String, number: Int)], token: String) async throws -> [RawActivityPr] {
    struct Entry: Decodable, Sendable { let pullRequest: RawActivityPr? }
    var prs: [RawActivityPr] = []
    for start in stride(from: 0, to: refs.count, by: prLookupChunk) {
      let chunk = refs[start ..< min(start + prLookupChunk, refs.count)]
      let selections = chunk.enumerated().map { index, ref in
        let parts = ref.repo.split(separator: "/").map(String.init)
        return """
          p\(index): repository(owner: \(jsonString(parts[0])), name: \(jsonString(parts.count > 1 ? parts[1] : ""))) {
            pullRequest(number: \(ref.number)) { \(activityPrFields) }
          }
          """
      }.joined(separator: "\n")
      let result = try await graphqlRaw("query PrsByNumber {\n\(selections)\n}", token: token, as: [String: Entry?].self)
      prs += (result.data ?? [:]).values.compactMap { $0?.pullRequest }
    }
    return prs
  }

  private static func jsonString(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
  }

  private static let eventPages = 3

  /// Your own events, newest first: pushes, PR actions, reviews and comments, private repos
  /// included because the token is yours. GitHub keeps 300 at most, so this covers days to weeks.
  static func userEvents(_ login: String, token: String) async throws -> (events: [RawGitHubEvent], capped: Bool) {
    var events: [RawGitHubEvent] = []
    for page in 1 ... eventPages {
      var request = URLRequest(url: URL(string: "https://api.github.com/users/\(login)/events?per_page=100&page=\(page)")!)
      request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
      request.setValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as! HTTPURLResponse).statusCode
      // Past the last page GitHub answers 422; anything before it is still good.
      if status == 422 && page > 1 { break }
      guard status == 200 else { throw IntegrationError("GitHub events \(status): \(String(decoding: data.prefix(200), as: UTF8.self))") }
      let batch = try JSONDecoder().decode([RawGitHubEvent].self, from: data)
      events += batch
      // GitHub stops near 300 rather than exactly at it, so reaching the last page means the cap
      // was hit; stopping earlier means the feed really ended.
      if batch.count < 100 && page < eventPages { return (events, false) }
    }
    return (events, true)
  }
}

struct LinearIssueActivity: Decodable, Sendable {
  struct State: Decodable, Sendable { let name: String; let type: String; let color: String }
  struct Named: Decodable, Sendable { let name: String }
  struct Assignee: Decodable, Sendable { let displayName: String }
  struct Creator: Decodable, Sendable { let isMe: Bool }
  struct Entry: Decodable, Sendable {
    struct Step: Decodable, Sendable { let name: String; let type: String }
    let createdAt: String
    let actor: Named?
    let fromState: Step?
    let toState: Step?
  }
  let identifier: String
  let title: String
  let url: String
  let createdAt: String
  let creator: Creator?
  let state: State
  let assignee: Assignee?
  let project: Named?
  let history: Nodes<Entry>

  var ticket: Ticket {
    Ticket(
      key: identifier, title: title, url: url, state: state.name, stateType: state.type, stateColor: state.color,
      assignee: assignee?.displayName, project: project?.name
    )
  }
}

extension Linear {
  private static let issueActivityPages = 5

  /// Issues assigned to you that changed since `from`, and issues you created in the range, with
  /// their state history. Paged, since a month back easily passes a hundred.
  static func myIssueActivity(from: String, to: String, apiKey: String) async throws -> (issues: [LinearIssueActivity], truncated: Bool) {
    struct Page: Decodable { struct Issues: Decodable { let pageInfo: PageInfo; let nodes: [LinearIssueActivity] }; let issues: Issues }
    var byKey: [String: LinearIssueActivity] = [:]
    var order: [String] = []
    var truncated = false
    let filters = [
      // Created after the range ends means nothing in it can be about the range.
      "{ assignee: { isMe: { eq: true } }, updatedAt: { gte: $from }, createdAt: { lt: $to } }",
      "{ creator: { isMe: { eq: true } }, createdAt: { gte: $from, lt: $to } }",
    ]
    for filter in filters {
      var after: String?
      for page in 0 ..< issueActivityPages {
        let result = try await graphql(
          """
          query MyIssueActivity($from: DateTimeOrDuration!, $to: DateTimeOrDuration!, $after: String) {
            issues(first: 100, after: $after, filter: \(filter)) {
              pageInfo { hasNextPage endCursor }
              nodes {
                identifier title url createdAt
                creator { isMe }
                state { name type color } assignee { displayName } project { name }
                history(first: 50) { nodes { createdAt actor { name } fromState { name type } toState { name type } } }
              }
            }
          }
          """,
          variables: ["from": from, "to": to, "after": after ?? NSNull()], apiKey: apiKey, as: Page.self
        ).issues
        for issue in result.nodes {
          if byKey[issue.identifier] == nil { order.append(issue.identifier) }
          byKey[issue.identifier] = issue
        }
        guard result.pageInfo.hasNextPage else { break }
        if page == issueActivityPages - 1 { truncated = true }
        after = result.pageInfo.endCursor
      }
    }
    return (order.compactMap { byKey[$0] }, truncated)
  }
}
