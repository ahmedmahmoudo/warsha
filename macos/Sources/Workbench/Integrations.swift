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

/// GitHub's GraphQL API. Ported from server/integrations/github.ts as the pages that need it are.
enum GitHub {
  private static let endpoint = URL(string: "https://api.github.com/graphql")!

  static func graphql<T: Decodable>(_ query: String, variables: [String: any Sendable] = [:], token: String, as: T.Type) async throws -> T {
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
    guard http.statusCode == 200 else { throw IntegrationError(describeFailure(http, body: data)) }
    let result = try JSONDecoder().decode(GraphqlResponse<T>.self, from: data)
    if let errors = result.errors, !errors.isEmpty {
      throw IntegrationError("GitHub: " + errors.map(\.message).joined(separator: "; "))
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
    if response.statusCode == 403, text.range(of: "SAML|SSO", options: .regularExpression) != nil {
      return "The GitHub token needs SSO authorization for the organization (403)"
    }
    return "GitHub \(response.statusCode): \(text)"
  }

  /// Who the token belongs to, for Settings' connection check.
  static func viewer(token: String) async throws -> String {
    struct Viewer: Decodable { struct Login: Decodable { let login: String }; let viewer: Login }
    return try await graphql("query { viewer { login } }", token: token, as: Viewer.self).viewer.login
  }
}

/// Linear's GraphQL API. Ported from server/integrations/linear.ts as the pages that need it are.
enum Linear {
  private static let endpoint = URL(string: "https://api.linear.app/graphql")!

  static func graphql<T: Decodable>(_ query: String, variables: [String: any Sendable] = [:], apiKey: String, as: T.Type) async throws -> T {
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
    if let errors = result.errors, !errors.isEmpty {
      throw IntegrationError("Linear: " + errors.map(\.message).joined(separator: "; "))
    }
    guard status == 200, let value = result.data else { throw IntegrationError("Linear \(status)") }
    return value
  }

  /// Who the key belongs to, for Settings' connection check.
  static func viewer(apiKey: String) async throws -> String {
    struct Viewer: Decodable { struct User: Decodable { let name: String; let email: String }; let viewer: User }
    let user = try await graphql("query { viewer { name email } }", apiKey: apiKey, as: Viewer.self).viewer
    return "\(user.name) (\(user.email))"
  }
}

private struct GraphqlResponse<T: Decodable>: Decodable {
  struct Failure: Decodable { let message: String }
  let data: T?
  let errors: [Failure]?
}
