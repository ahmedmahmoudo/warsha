import AppKit
import CryptoKit
import Foundation
import Network

// Signing in to GitHub and Linear with Workbench's own OAuth apps, as an alternative to pasting a
// token. Their client IDs are baked in at build time (Secrets.xcconfig); neither needs a secret:
// GitHub through its device flow, Linear through PKCE.

/// A signed-in account's tokens, kept in the Keychain as JSON.
struct OAuthGrant: Codable, Equatable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var expiresAt: Date?
  /// Who signed in, for Settings: a GitHub login, or "Name · Workspace" in Linear.
  var account: String

  /// Close enough to expiring that it's worth renewing now.
  var isStale: Bool { expiresAt.map { $0.timeIntervalSinceNow < 15 * 60 } ?? false }
}

enum OAuth {
  /// A client ID from the app's Info.plist; nil in builds without one (the SwiftPM build), which
  /// then offer only tokens.
  static func clientId(_ key: String) -> String? {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
  }

  static func randomURLSafe(_ bytes: Int) -> String {
    Data((0 ..< bytes).map { _ in UInt8.random(in: 0 ... 255) }).base64URLEncoded
  }

  static func form(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }.joined(separator: "&").utf8)
  }

  /// POSTs a form and reads back JSON, whatever the status: OAuth errors come as JSON too.
  static func post(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = form(fields)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    let (data, _) = try await URLSession.shared.data(for: request)
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  static func expiry(_ tokens: [String: Any]) -> Date? {
    (tokens["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
  }
}

// MARK: GitHub

/// GitHub's device flow: Workbench shows a short code, you enter it at github.com/login/device, and
/// Workbench collects the token. Tokens last 8 hours when the app has expiring tokens on, with a
/// refresh token to renew them.
enum GitHubSignIn {
  static let clientIdKey = "WorkbenchGitHubClientId"
  static let scopes = "repo read:org"
  private static let codeURL = URL(string: "https://github.com/login/device/code")!
  private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

  struct DeviceCode: Sendable, Equatable {
    let userCode: String
    let verificationURL: URL
    let deviceCode: String
    let interval: Int
    let expiresAt: Date
  }

  static func start(clientId: String) async throws -> DeviceCode {
    let response = try await OAuth.post(codeURL, ["client_id": clientId, "scope": scopes])
    guard let userCode = response["user_code"] as? String, let deviceCode = response["device_code"] as? String,
          let url = (response["verification_uri"] as? String).flatMap(URL.init(string:))
    else { throw IntegrationError("GitHub didn't start the sign-in: \(response["error_description"] as? String ?? response["error"] as? String ?? "no code")") }
    return DeviceCode(
      userCode: userCode, verificationURL: url, deviceCode: deviceCode, interval: response["interval"] as? Int ?? 5,
      expiresAt: Date().addingTimeInterval(response["expires_in"] as? Double ?? 900)
    )
  }

  /// Waits for you to approve the code, polling as GitHub asks. Cancel the task to stop.
  static func finish(_ code: DeviceCode, clientId: String) async throws -> OAuthGrant {
    var interval = code.interval
    while Date() < code.expiresAt {
      try await Task.sleep(for: .seconds(interval))
      let tokens = try await OAuth.post(tokenURL, [
        "client_id": clientId, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
      ])
      if let access = tokens["access_token"] as? String {
        let login = try await GitHub.viewer(token: access)
        return OAuthGrant(accessToken: access, refreshToken: tokens["refresh_token"] as? String, expiresAt: OAuth.expiry(tokens), account: login)
      }
      switch tokens["error"] as? String {
      case "authorization_pending": continue
      case "slow_down": interval = tokens["interval"] as? Int ?? interval + 5
      case "access_denied": throw IntegrationError("You cancelled the GitHub sign-in.")
      case "expired_token": throw IntegrationError("The code expired. Sign in again.")
      default: throw IntegrationError("GitHub sign-in failed: \(tokens["error_description"] as? String ?? tokens["error"] as? String ?? "no token")")
      }
    }
    throw IntegrationError("The code expired. Sign in again.")
  }

  static func refresh(_ grant: OAuthGrant, clientId: String) async throws -> OAuthGrant {
    guard let refreshToken = grant.refreshToken else { throw SignInExpired(service: "GitHub") }
    let tokens = try await OAuth.post(tokenURL, ["client_id": clientId, "grant_type": "refresh_token", "refresh_token": refreshToken])
    guard let access = tokens["access_token"] as? String else { throw SignInExpired(service: "GitHub", detail: tokens["error_description"] as? String) }
    return OAuthGrant(accessToken: access, refreshToken: tokens["refresh_token"] as? String ?? refreshToken, expiresAt: OAuth.expiry(tokens), account: grant.account)
  }
}

// MARK: Linear

/// Linear's OAuth in the browser, back to a listener on this Mac, with PKCE instead of a secret.
/// Access tokens last a day; the refresh token renews them. Whichever workspace is open in your
/// browser is the one Workbench gets.
enum LinearSignIn {
  static let clientIdKey = "WorkbenchLinearClientId"
  /// Registered with the Linear app as its callback, so it can't move.
  static let port: UInt16 = 53682
  static let redirectURI = "http://localhost:53682/callback"
  private static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!
  private static let revokeURL = URL(string: "https://api.linear.app/oauth/revoke")!

  static func signIn(clientId: String) async throws -> OAuthGrant {
    let verifier = OAuth.randomURLSafe(32)
    let state = OAuth.randomURLSafe(16)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    let callback = LoopbackCallback(service: "Linear")
    _ = try await callback.start(port: port)

    var components = URLComponents(string: "https://linear.app/oauth/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      // Read everything, and comment for Park & Post.
      URLQueryItem(name: "scope", value: "read,comments:create"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    await MainActor.run { _ = NSWorkspace.shared.open(components.url!) }

    let query = try await callback.wait()
    if let error = query["error"] {
      throw IntegrationError(error == "access_denied" ? "You cancelled the Linear sign-in." : "Linear returned: \(error)")
    }
    guard let code = query["code"], query["state"] == state else { throw IntegrationError("Linear sent back an incomplete sign-in.") }
    let tokens = try await OAuth.post(tokenURL, [
      "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "client_id": clientId, "code_verifier": verifier,
    ])
    guard let access = tokens["access_token"] as? String else {
      throw IntegrationError("Linear refused the sign-in: \(tokens["error_description"] as? String ?? tokens["error"] as? String ?? "no token")")
    }
    return OAuthGrant(
      accessToken: access, refreshToken: tokens["refresh_token"] as? String, expiresAt: OAuth.expiry(tokens),
      account: try await account(authorization: "Bearer \(access)")
    )
  }

  static func refresh(_ grant: OAuthGrant, clientId: String) async throws -> OAuthGrant {
    guard let refreshToken = grant.refreshToken else { throw SignInExpired(service: "Linear") }
    let tokens = try await OAuth.post(tokenURL, ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId])
    guard let access = tokens["access_token"] as? String else { throw SignInExpired(service: "Linear", detail: tokens["error_description"] as? String) }
    return OAuthGrant(accessToken: access, refreshToken: tokens["refresh_token"] as? String ?? refreshToken, expiresAt: OAuth.expiry(tokens), account: grant.account)
  }

  static func revoke(_ grant: OAuthGrant) async {
    var request = URLRequest(url: revokeURL)
    request.httpMethod = "POST"
    request.httpBody = OAuth.form(["token": grant.accessToken])
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.setValue("Bearer \(grant.accessToken)", forHTTPHeaderField: "authorization")
    _ = try? await URLSession.shared.data(for: request)
  }

  /// "Name · Workspace", so it's clear which workspace the sign-in reached.
  private static func account(authorization: String) async throws -> String {
    struct Viewer: Decodable {
      struct User: Decodable { let name: String }
      struct Organization: Decodable { let name: String }
      let viewer: User
      let organization: Organization
    }
    let result = try await Linear.graphql("query { viewer { name } organization { name } }", apiKey: authorization, as: Viewer.self)
    return "\(result.viewer.name) · \(result.organization.name)"
  }
}

/// A sign-in that can no longer be renewed: revoked, or unused too long.
struct SignInExpired: LocalizedError {
  let service: String
  var detail: String?
  var errorDescription: String? { "Your \(service) sign-in expired\(detail.map { " (\($0))" } ?? ""). Sign in again in Settings → Accounts." }
}

// MARK: Keeping sign-ins fresh

/// The sign-ins in progress, for Settings, and renewing them before they expire.
@MainActor
@Observable
final class SignIns {
  /// GitHub's code while it waits for you to enter it.
  private(set) var githubCode: GitHubSignIn.DeviceCode?
  private(set) var githubBusy = false
  private(set) var linearBusy = false
  /// The last thing that went wrong, per service, until the next try.
  var githubError: String?
  var linearError: String?

  @ObservationIgnored private var githubTask: Task<Void, Never>?
  @ObservationIgnored private var refreshing: Task<Void, Never>?

  var githubClientId: String? { OAuth.clientId(GitHubSignIn.clientIdKey) }
  var linearClientId: String? { OAuth.clientId(LinearSignIn.clientIdKey) }

  func signInToGitHub(_ settings: AppSettings) {
    guard let clientId = githubClientId, !githubBusy else { return }
    githubBusy = true
    githubError = nil
    githubTask = Task {
      defer { githubBusy = false; githubCode = nil }
      do {
        let code = try await GitHubSignIn.start(clientId: clientId)
        githubCode = code
        copyAndOpen(code)
        settings.githubSignIn = try await GitHubSignIn.finish(code, clientId: clientId)
      } catch is CancellationError {
      } catch {
        githubError = error.localizedDescription
      }
    }
  }

  /// The code goes on the clipboard and GitHub's page opens, so it's paste and approve.
  func copyAndOpen(_ code: GitHubSignIn.DeviceCode) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code.userCode, forType: .string)
    NSWorkspace.shared.open(code.verificationURL)
  }

  func cancelGitHub() { githubTask?.cancel() }

  func signInToLinear(_ settings: AppSettings) {
    guard let clientId = linearClientId, !linearBusy else { return }
    linearBusy = true
    linearError = nil
    Task {
      defer { linearBusy = false }
      do {
        settings.linearSignIn = try await LinearSignIn.signIn(clientId: clientId)
      } catch {
        linearError = error.localizedDescription
      }
    }
  }

  func signOutOfGitHub(_ settings: AppSettings) { settings.githubSignIn = nil }

  func signOutOfLinear(_ settings: AppSettings) {
    if let grant = settings.linearSignIn { Task { await LinearSignIn.revoke(grant) } }
    settings.linearSignIn = nil
  }

  /// Renews any sign-in close to expiring; the background loops call it before each load, and
  /// waking the Mac does too. One renewal at a time.
  func refreshIfNeeded(_ settings: AppSettings) async {
    if let refreshing { return await refreshing.value }
    guard settings.githubSignIn?.isStale == true || settings.linearSignIn?.isStale == true else { return }
    let task = Task {
      if let grant = settings.githubSignIn, grant.isStale, let clientId = githubClientId {
        do { settings.githubSignIn = try await GitHubSignIn.refresh(grant, clientId: clientId) } catch let expired as SignInExpired {
          settings.githubSignIn = nil
          githubError = expired.localizedDescription
        } catch {}
      }
      if let grant = settings.linearSignIn, grant.isStale, let clientId = linearClientId {
        do { settings.linearSignIn = try await LinearSignIn.refresh(grant, clientId: clientId) } catch let expired as SignInExpired {
          settings.linearSignIn = nil
          linearError = expired.localizedDescription
        } catch {}
      }
    }
    refreshing = task
    await task.value
    refreshing = nil
  }
}

// MARK: Browser callback

/// A one-shot HTTP listener on 127.0.0.1 for a sign-in's redirect: it answers the browser with a
/// short page and hands back the query string. Gives up after five minutes.
final class LoopbackCallback: @unchecked Sendable {
  /// Named on the page the browser shows: "Workbench is connected to Linear."
  let service: String
  private let queue = DispatchQueue(label: "com.workbench.oauth-callback")
  private var listener: NWListener?
  private var continuation: CheckedContinuation<[String: String], any Error>?
  private var finished = false
  /// Whether start() has heard back yet; touched only on `queue`.
  private var started = false

  init(service: String) { self.service = service }

  /// Listens on the given port, or any free one; returns the port.
  func start(port: UInt16? = nil) async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
      listener.stateUpdateHandler = { [self] state in
        guard !started else { return }
        switch state {
        case .ready:
          started = true
          ready.resume(returning: listener.port?.rawValue ?? 0)
        case let .failed(error), let .waiting(error):
          started = true
          listener.cancel()
          ready.resume(throwing: port == nil ? error : IntegrationError("Port \(port!) is in use, so the \(service) sign-in can't come back. Close whatever is using it and try again."))
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
      listener.start(queue: queue)
    }
  }

  func wait() async throws -> [String: String] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.continuation = continuation
        self.queue.asyncAfter(deadline: .now() + 300) { self.finish(.failure(IntegrationError("The \(self.service) sign-in timed out. Try again."))) }
      }
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
      guard let self else { return }
      let request = String(decoding: data ?? Data(), as: UTF8.self)
      // "GET /callback?code=…&state=… HTTP/1.1"
      let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
      guard target.hasPrefix("/callback") else {
        connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
        return
      }
      var query: [String: String] = [:]
      for item in URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? [] { query[item.name] = item.value ?? "" }
      let ok = query["code"] != nil
      let page = """
        <!doctype html><meta charset="utf-8"><title>Workbench</title>
        <body style="font: 15px -apple-system, sans-serif; padding: 40px; color: #1c1c1a">
        <p>\(ok ? "Workbench is connected to \(service). You can close this tab." : "The \(service) sign-in didn't finish. You can close this tab and try again from Workbench.")</p>
        </body>
        """
      let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      self.finish(.success(query))
    }
  }

  private func finish(_ result: Result<[String: String], any Error>) {
    guard !finished, let continuation else { return }
    finished = true
    self.continuation = nil
    listener?.cancel()
    continuation.resume(with: result)
  }
}

extension Data {
  var base64URLEncoded: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLEncoded text: String) {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }
}
