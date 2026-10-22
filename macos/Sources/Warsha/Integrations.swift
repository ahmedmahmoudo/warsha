import Foundation

/// The setting an integration needs is blank: shown as "set this up", not as a failure.
struct NotConfigured: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

struct IntegrationError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

struct GraphqlError: Decodable, Sendable {
  let message: String
  let type: String?
  /// Field names and list indexes, all as text.
  let path: [String]?

  private enum Keys: String, CodingKey { case message, type, path }
  private struct Segment: Decodable {
    let text: String
    init(from decoder: any Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let name = try? value.decode(String.self) { text = name } else { text = String(try value.decode(Int.self)) }
    }
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    message = try c.decode(String.self, forKey: .message)
    type = try c.decodeIfPresent(String.self, forKey: .type)
    path = try c.decodeIfPresent([Segment].self, forKey: .path)?.map(\.text)
  }

  var formatted: String {
    "\(type ?? "ERROR")\(path.map { " at \($0.joined(separator: "."))" } ?? ""): \(message)"
  }
}

/// Partial data alongside per-field errors, and the response headers; the token check needs all three.
struct RawResult<T: Sendable>: Sendable {
  let data: T?
  let errors: [GraphqlError]
  /// Lower-cased names.
  let headers: [String: String]
}

private struct GraphqlResponse<T: Decodable>: Decodable {
  let data: T?
  let errors: [GraphqlError]?
}

/// GitHub's GraphQL API. Ported from server/integrations/github.ts as the pages that need it are.
enum GitHub {
  private static let endpoint = URL(string: "https://api.github.com/graphql")!

  static func graphqlRaw<T: Decodable & Sendable>(
    _ query: String, variables: [String: any Sendable] = [:], token: String, as: T.Type
  ) async throws -> RawResult<T> {
    guard !token.isEmpty else { throw NotConfigured("Add a GitHub token in Settings.") }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    // mergeStateStatus is still gated behind this preview on some GitHub API versions.
    request.setValue("application/vnd.github.merge-info-preview+json", forHTTPHeaderField: "accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    guard http.statusCode == 200 else {
      var headers: [String: String] = [:]
      for case let (name as String, value as String) in http.allHeaderFields { headers[name.lowercased()] = value }
      RateBudget.shared.record(headers)
      throw IntegrationError(describeFailure(http, body: data))
    }
    let result = try JSONDecoder().decode(GraphqlResponse<T>.self, from: data)
    var headers: [String: String] = [:]
    for case let (name as String, value as String) in http.allHeaderFields { headers[name.lowercased()] = value }
    RateBudget.shared.record(headers)
    return RawResult(data: result.data, errors: result.errors ?? [], headers: headers)
  }

  static func graphql<T: Decodable & Sendable>(
    _ query: String, variables: [String: any Sendable] = [:], token: String, as type: T.Type
  ) async throws -> T {
    let result = try await graphqlRaw(query, variables: variables, token: token, as: type)
    if !result.errors.isEmpty {
      throw IntegrationError("GitHub: " + result.errors.map(\.formatted).joined(separator: "; "))
    }
    guard let value = result.data else { throw IntegrationError("GitHub returned no data") }
    return value
  }

  /// Turns an HTTP failure into something that says what to fix, not just the status code.
  private static func describeFailure(_ response: HTTPURLResponse, body: Data) -> String {
    let text = String(decoding: body.prefix(300), as: UTF8.self)
    if response.statusCode == 401 { return "GitHub rejected the token (401): it is wrong, revoked or expired" }
    if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
       let reset = Double(response.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") {
      return "GitHub rate limit used up; it resets at \(Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened))"
    }
    if response.statusCode == 403, let restricted = oauthRestriction(String(decoding: body, as: UTF8.self)) { return restricted }
    if response.statusCode == 403, text.range(of: "SAML|SSO", options: .regularExpression) != nil {
      return "The GitHub token needs SSO authorization for the organization (403)"
    }
    return "GitHub \(response.statusCode): \(text)"
  }

  /// Who the token belongs to.
  static func viewer(token: String) async throws -> String {
    struct Viewer: Decodable { struct Login: Decodable { let login: String }; let viewer: Login }
    return try await graphql("query { viewer { login } }", token: token, as: Viewer.self).viewer.login
  }
}

/// Linear's GraphQL API. Ported from server/integrations/linear.ts as the pages that need it are.
enum Linear {
  private static let endpoint = URL(string: "https://api.linear.app/graphql")!

  static func graphql<T: Decodable & Sendable>(
    _ query: String, variables: [String: any Sendable] = [:], apiKey: String, as: T.Type
  ) async throws -> T {
    let (data, errors, status) = try await post(query, variables: variables, apiKey: apiKey, as: T.self)
    if !errors.isEmpty { throw IntegrationError("Linear: " + errors.map(\.message).joined(separator: "; ")) }
    guard status == 200, let data else { throw IntegrationError("Linear \(status)") }
    return data
  }

  /// Data and errors as they came, for queries where some fields failing is expected.
  static func post<T: Decodable & Sendable>(
    _ query: String, variables: [String: any Sendable], apiKey: String, as: T.Type
  ) async throws -> (T?, [GraphqlError], Int) {
    guard !apiKey.isEmpty else { throw NotConfigured("Add a Linear API key in Settings.") }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    // Personal API keys go in as they are, without "Bearer".
    request.setValue(apiKey, forHTTPHeaderField: "authorization")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    guard let result = try? JSONDecoder().decode(GraphqlResponse<T>.self, from: data) else {
      throw IntegrationError("Linear \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return (result.data, result.errors ?? [], status)
  }

  /// Who the key belongs to, for Settings' connection check.
  static func viewer(apiKey: String) async throws -> String {
    struct Viewer: Decodable { struct User: Decodable { let name: String; let email: String }; let viewer: User }
    let user = try await graphql("query { viewer { name email } }", apiKey: apiKey, as: Viewer.self).viewer
    return "\(user.name) (\(user.email))"
  }

  private struct RawIssue: Decodable, Sendable {
    struct State: Decodable { let name: String; let type: String; let color: String }
    struct Named: Decodable { let name: String }
    struct Assignee: Decodable { let displayName: String }
    let identifier: String
    let title: String
    let url: String
    let state: State
    let assignee: Assignee?
    let project: Named?
  }

  /// Tickets by key. Keys that aren't real tickets come back as errors for their field, with the
  /// rest still answered, so those errors are ignored.
  static func tickets(_ keys: [String], apiKey: String) async throws -> [String: Ticket] {
    guard !apiKey.isEmpty else { throw NotConfigured("Add a Linear API key in Settings.") }
    guard !keys.isEmpty else { return [:] }
    let definitions = keys.indices.map { "$k\($0): String!" }.joined(separator: ", ")
    let selections = keys.indices.map {
      "t\($0): issue(id: $k\($0)) { identifier title url state { name type color } assignee { displayName } project { name } }"
    }.joined(separator: "\n")
    var variables: [String: any Sendable] = [:]
    for (index, key) in keys.enumerated() { variables["k\(index)"] = key }
    let (data, _, status) = try await post(
      "query Tickets(\(definitions)) {\n\(selections)\n}", variables: variables, apiKey: apiKey, as: [String: RawIssue?].self
    )
    guard status == 200 || status == 400 else { throw IntegrationError("Linear \(status)") }
    var tickets: [String: Ticket] = [:]
    for case let issue? in (data ?? [:]).values {
      tickets[issue.identifier] = Ticket(
        key: issue.identifier, title: issue.title, url: issue.url, state: issue.state.name, stateType: issue.state.type,
        stateColor: issue.state.color, assignee: issue.assignee?.displayName, project: issue.project?.name
      )
    }
    return tickets
  }
}

/// GitHub's GraphQL points left this hour, from the headers of the last response. The budget is
/// the token's, so it's shared with anything else using it (the gh CLI's token is everyone's on
/// that Mac). Background refreshes stand down when it's low rather than spend the rest.
final class RateBudget: @unchecked Sendable {
  static let shared = RateBudget()
  /// Below this share of the hour's points, only what you ask for (Refresh, opening a PR) runs.
  static let reserve = 0.1

  private let lock = NSLock()
  private var remaining: Int?
  private var limit: Int?
  private var resetAt: Date?

  func record(_ headers: [String: String]) {
    guard let left = headers["x-ratelimit-remaining"].flatMap(Int.init) else { return }
    lock.withLock {
      remaining = left
      limit = headers["x-ratelimit-limit"].flatMap(Int.init) ?? limit
      resetAt = headers["x-ratelimit-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? resetAt
    }
  }

  /// When the points are nearly gone: until when background refreshes wait. Nil when they're fine.
  var lowUntil: Date? {
    lock.withLock {
      guard let remaining, let limit, let resetAt, resetAt > Date() else { return nil }
      return Double(remaining) < Double(limit) * Self.reserve ? resetAt : nil
    }
  }

  var summary: (remaining: Int, limit: Int)? {
    lock.withLock { remaining.flatMap { left in limit.map { (left, $0) } } }
  }
}
