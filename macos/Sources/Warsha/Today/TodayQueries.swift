import Foundation

// Linear and GitHub queries for Today and parking: from server/integrations/linear.ts and github.ts.

struct RawNotification: Decodable, Sendable {
  struct Actor: Decodable, Sendable { let name: String; let avatarUrl: String? }
  struct Issue: Decodable, Sendable {
    struct State: Decodable, Sendable { let name: String; let type: String; let color: String }
    let identifier: String
    let title: String
    let url: String
    let state: State
  }
  struct Body: Decodable, Sendable { let body: String; let url: String }
  struct Project: Decodable, Sendable { let name: String; let url: String }

  let id: String
  let type: String
  let createdAt: String
  let readAt: String?
  let archivedAt: String?
  let actor: Actor?
  let issue: Issue?
  let comment: Body?
  let project: Project?
  let projectUpdate: Body?
}

extension Linear {
  private static let openTicketPages = 3

  /// Everything assigned to you that isn't finished, with what decides its priority.
  static func myOpenTickets(apiKey: String) async throws -> [OpenTicket] {
    struct Page: Decodable {
      struct Issues: Decodable { let pageInfo: PageInfo; let nodes: [Raw] }
      struct Raw: Decodable {
        struct State: Decodable { let name: String; let type: String; let color: String }
        struct Assignee: Decodable { let displayName: String }
        struct Project: Decodable { struct Status: Decodable { let type: String }; let name: String; let url: String; let targetDate: String?; let status: Status? }
        struct Cycle: Decodable { let number: Int; let startsAt: String; let endsAt: String }
        struct Label: Decodable { let name: String }
        struct Entry: Decodable { struct Me: Decodable { let isMe: Bool }; let createdAt: String; let toAssignee: Me? }
        let identifier: String
        let title: String
        let url: String
        let priority: Int
        let priorityLabel: String
        let createdAt: String
        let state: State
        let assignee: Assignee?
        let project: Project?
        let cycle: Cycle?
        let labels: Nodes<Label>
        let history: Nodes<Entry>
      }
      let issues: Issues
    }
    var tickets: [OpenTicket] = []
    var after: String?
    for _ in 0 ..< openTicketPages {
      let page = try await graphql(
        """
        query MyOpenTickets($after: String) {
          issues(first: 100, after: $after, filter: {
            assignee: { isMe: { eq: true } }
            state: { type: { nin: ["completed", "canceled"] } }
          }) {
            pageInfo { hasNextPage endCursor }
            nodes {
              identifier title url priority priorityLabel createdAt
              state { name type color } assignee { displayName }
              project { name url targetDate status { type } }
              cycle { number startsAt endsAt }
              labels(first: 10) { nodes { name } }
              history(first: 30) { nodes { createdAt toAssignee { isMe } } }
            }
          }
        }
        """,
        variables: ["after": after ?? NSNull()], apiKey: apiKey, as: Page.self
      ).issues
      for raw in page.nodes {
        tickets.append(OpenTicket(
          ticket: Ticket(
            key: raw.identifier, title: raw.title, url: raw.url, state: raw.state.name, stateType: raw.state.type,
            stateColor: raw.state.color, assignee: raw.assignee?.displayName, project: raw.project?.name
          ),
          priority: raw.priority, priorityLabel: raw.priorityLabel, labels: raw.labels.nodes.map(\.name), createdAt: raw.createdAt,
          assignedAt: raw.history.nodes.filter { $0.toAssignee?.isMe == true }.map(\.createdAt).max(),
          projectInfo: raw.project.map {
            OpenTicket.ProjectInfo(name: $0.name, url: $0.url, targetDate: $0.targetDate, statusType: $0.status?.type)
          },
          cycle: raw.cycle.map { OpenTicket.Cycle(number: $0.number, startsAt: $0.startsAt, endsAt: $0.endsAt) }
        ))
      }
      guard page.pageInfo.hasNextPage else { break }
      after = page.pageInfo.endCursor
    }
    return tickets
  }

  /// Notification kinds that are reminders rather than news.
  private static let ignoredNotifications: Set = ["projectUpdatePrompt", "projectDescriptionContentChange"]

  /// Your Linear inbox, newest first: assignments, comments, mentions, status and priority changes.
  static func myNotifications(apiKey: String) async throws -> [RawNotification] {
    struct Result: Decodable { let notifications: Nodes<RawNotification> }
    return try await graphql(
      """
      query MyNotifications($first: Int!) {
        notifications(first: $first) { nodes {
          id type createdAt readAt archivedAt
          actor { name avatarUrl }
          ... on IssueNotification {
            issue { identifier title url state { name type color } }
            comment { body url }
          }
          ... on ProjectNotification {
            project { name url }
            projectUpdate { body url }
            comment { body url }
          }
        } }
      }
      """,
      variables: ["first": 100], apiKey: apiKey, as: Result.self
    ).notifications.nodes.filter { $0.archivedAt == nil && !ignoredNotifications.contains($0.type) }
  }

  /// When each ticket entered the status it's in now: the latest move into that status, else when
  /// work started, else when it was created. Unknown keys come back as errors for their field.
  static func stateSince(_ keys: [String], apiKey: String) async throws -> [String: String] {
    guard !keys.isEmpty else { return [:] }
    struct Raw: Decodable, Sendable {
      struct State: Decodable, Sendable { let name: String }
      struct Entry: Decodable, Sendable { let createdAt: String; let toState: State? }
      let identifier: String
      let createdAt: String
      let startedAt: String?
      let state: State
      let history: Nodes<Entry>
    }
    let definitions = keys.indices.map { "$k\($0): String!" }.joined(separator: ", ")
    let selections = keys.indices.map {
      "t\($0): issue(id: $k\($0)) { identifier createdAt startedAt state { name } history(first: 50) { nodes { createdAt toState { name } } } }"
    }.joined(separator: "\n")
    var variables: [String: any Sendable] = [:]
    for (index, key) in keys.enumerated() { variables["k\(index)"] = key }
    let (data, _, status) = try await post(
      "query StateSince(\(definitions)) {\n\(selections)\n}", variables: variables, apiKey: apiKey, as: [String: Raw?].self
    )
    guard status == 200 || status == 400 else { throw IntegrationError("Linear \(status)") }
    var since: [String: String] = [:]
    for case let issue? in (data ?? [:]).values {
      let entered = issue.history.nodes.filter { $0.toState?.name == issue.state.name }.map(\.createdAt).max()
      since[issue.identifier] = entered ?? issue.startedAt ?? issue.createdAt
    }
    return since
  }

  /// Posts a comment on a Linear ticket, as you. Returns the comment's link.
  static func comment(on key: String, body: String, apiKey: String) async throws -> String {
    struct Found: Decodable { struct Issue: Decodable { let id: String }; let issue: Issue? }
    guard let issue = try await graphql(
      "query IssueId($key: String!) { issue(id: $key) { id } }", variables: ["key": key], apiKey: apiKey, as: Found.self
    ).issue else { throw IntegrationError("\(key) wasn't found in Linear") }
    struct Created: Decodable {
      struct Result: Decodable { struct Comment: Decodable { let url: String }; let success: Bool; let comment: Comment? }
      let commentCreate: Result
    }
    let result = try await graphql(
      """
      mutation Comment($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) { success comment { url } }
      }
      """,
      variables: ["issueId": issue.id, "body": body], apiKey: apiKey, as: Created.self
    ).commentCreate
    guard result.success, let comment = result.comment else { throw IntegrationError("Linear didn't accept the comment on \(key)") }
    return comment.url
  }
}

extension GitHub {
  /// A team's members, for naming who to nudge. Needs read:org.
  static func teamMembers(org: String, slug: String, token: String) async throws -> [Person] {
    struct Result: Decodable {
      struct Org: Decodable {
        struct Team: Decodable {
          struct Member: Decodable { let login: String; let name: String?; let avatarUrl: String }
          let members: Nodes<Member>
        }
        let team: Team?
      }
      let organization: Org?
    }
    let members = try await graphql(
      """
      query TeamMembers($org: String!, $slug: String!) {
        organization(login: $org) { team(slug: $slug) { members(first: 100) { nodes { login name avatarUrl(size: 48) } } } }
      }
      """,
      variables: ["org": org, "slug": slug], token: token, as: Result.self
    ).organization?.team?.members.nodes ?? []
    return members.map {
      Person(kind: .user, id: $0.login, name: $0.name ?? $0.login, avatarUrl: $0.avatarUrl, url: "https://github.com/\($0.login)")
    }
  }

  /// Posts a comment on a PR, as you. Returns the comment's link.
  static func comment(on repo: String, number: Int, body: String, token: String) async throws -> String {
    guard !token.isEmpty else { throw NotConfigured("Add a GitHub token in Settings.") }
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/issues/\(number)/comments")!)
    request.httpMethod = "POST"
    request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    guard status == 201, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let url = json["html_url"] as? String else {
      throw IntegrationError("GitHub \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return url
  }
}
