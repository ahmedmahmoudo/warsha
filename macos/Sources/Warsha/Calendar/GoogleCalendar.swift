import AppKit
import CryptoKit
import Foundation
import Network

/// A Google event as Warsha keeps it: timed events as UTC ISO instants, all-day ones as
/// YYYY-MM-DD with an exclusive end.
struct GoogleEvent: Sendable {
  let id: String
  let cancelled: Bool
  let title: String
  let start: String
  let end: String
  let allDay: Bool
  let joinUrl: String?
  let htmlUrl: String?
  let location: String?
  /// Your answer to the invite; nil when you organised it or aren't listed.
  let response: String?
}

/// Google Calendar through OAuth with a Desktop client: server/integrations/google.ts in Swift. The
/// refresh token lives in the Keychain; access tokens only in memory.
actor GoogleCalendar {
  static let shared = GoogleCalendar()

  private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
  private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  private static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
  private static let calendarAPI = "https://www.googleapis.com/calendar/v3/calendars/primary"
  private static let scopes = ["openid", "email", "https://www.googleapis.com/auth/calendar.readonly"]

  /// Keychain keys (the refresh token) and Store settings (the email, which isn't secret).
  static let refreshTokenKey = "googleRefreshToken"
  static let emailSetting = "google.email"
  /// Where the web version kept the refresh token, in the database you may have imported.
  static let legacyRefreshTokenSetting = "google.refreshToken"

  struct Client: Sendable {
    let id: String
    let secret: String
  }

  /// The access token and the refresh token it came from: each profile has its own Google account.
  private var accessToken: (value: String, expiresAt: Date, refreshToken: String)?

  // MARK: Sign-in

  /// Signs in the way a desktop app should: Google's page opens in your browser, which comes back to
  /// a listener on 127.0.0.1 here, and the code is traded for tokens (PKCE-protected). Returns the
  /// refresh token and the account's email.
  func signIn(client: Client) async throws -> (refreshToken: String, email: String?) {
    let verifier = Self.randomURLSafe(32)
    let state = Self.randomURLSafe(16)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded

    let callback = LoopbackCallback(service: "Google Calendar")
    let port = try await callback.start()
    let redirectUri = "http://127.0.0.1:\(port)/callback"
    var components = URLComponents(string: Self.authURL)!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: client.id),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      // Offline + consent so Google always hands back a refresh token, even when reconnecting.
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "include_granted_scopes", value: "true"),
    ]
    await MainActor.run { _ = NSWorkspace.shared.open(components.url!) }

    let query = try await callback.wait()
    if let error = query["error"] {
      throw IntegrationError(error == "access_denied" ? "You cancelled the Google sign-in." : "Google returned: \(error)")
    }
    guard let code = query["code"], query["state"] == state else { throw IntegrationError("Google sent back an incomplete sign-in.") }

    let tokens = try await tokenRequest([
      "client_id": client.id, "client_secret": client.secret, "code": code, "code_verifier": verifier,
      "grant_type": "authorization_code", "redirect_uri": redirectUri,
    ])
    guard let access = tokens["access_token"] as? String else {
      throw IntegrationError("Google refused the sign-in: \(tokens["error_description"] as? String ?? "no access token")")
    }
    guard let refresh = tokens["refresh_token"] as? String else {
      throw IntegrationError("Google sent no refresh token. Remove Warsha from your Google account access and connect again.")
    }
    guard (tokens["scope"] as? String)?.contains("calendar.readonly") == true else {
      throw IntegrationError("Calendar access was not granted. Connect again and tick the calendar permission.")
    }
    accessToken = (access, Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 0), refresh)
    return (refresh, (tokens["id_token"] as? String).flatMap(Self.email(fromIdToken:)))
  }

  /// Revokes Warsha's access at Google; the caller forgets the token and the meetings.
  func revoke(refreshToken: String) async {
    accessToken = nil
    var request = URLRequest(url: Self.revokeURL)
    request.httpMethod = "POST"
    request.httpBody = Self.form(["token": refreshToken])
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    _ = try? await URLSession.shared.data(for: request)
  }

  func forgetAccessToken() { accessToken = nil }

  /// The ID token came straight from Google's token endpoint over TLS, so its claims are read
  /// without verifying the signature.
  private static func email(fromIdToken token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count > 1, let data = Data(base64URLEncoded: String(parts[1])),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return claims["email"] as? String
  }

  // MARK: Tokens

  /// Thrown when the stored refresh token no longer works: revoked, expired, or the password changed.
  struct Revoked: LocalizedError {
    var errorDescription: String? { "Google access was revoked or expired. Connect it again in Settings." }
  }

  private func validAccessToken(client: Client, refreshToken: String) async throws -> String {
    if let accessToken, accessToken.refreshToken == refreshToken, accessToken.expiresAt.timeIntervalSinceNow > 60 { return accessToken.value }
    let tokens = try await tokenRequest([
      "client_id": client.id, "client_secret": client.secret, "refresh_token": refreshToken, "grant_type": "refresh_token",
    ])
    if tokens["error"] as? String == "invalid_grant" { throw Revoked() }
    guard let access = tokens["access_token"] as? String else { throw IntegrationError("Google token refresh failed") }
    accessToken = (access, Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 0), refreshToken)
    return access
  }

  private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.httpBody = Self.form(fields)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    let (data, _) = try await URLSession.shared.data(for: request)
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  // MARK: Events

  private struct RawEvent: Decodable {
    struct Time: Decodable { let dateTime: String?; let date: String? }
    struct Conference: Decodable { struct Entry: Decodable { let entryPointType: String?; let uri: String? }; let entryPoints: [Entry]? }
    struct Attendee: Decodable {
      let isSelf: Bool?
      let responseStatus: String?
      private enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
    }
    let id: String
    let status: String?
    let summary: String?
    let htmlLink: String?
    let location: String?
    let description: String?
    let hangoutLink: String?
    let conferenceData: Conference?
    let attendees: [Attendee]?
    let start: Time?
    let end: Time?
  }

  private static let meetingLink = #"https://[^\s"'<>]*(?:zoom\.us/j|meet\.google\.com|teams\.microsoft\.com/l/meetup-join|teams\.live\.com)[^\s"'<>]*"#

  /// UTC ISO with milliseconds, as JavaScript's toISOString writes it, or the all-day date.
  private static func instant(_ time: RawEvent.Time?) -> String {
    if let dateTime = time?.dateTime, let date = TodayRules.parseInstant(dateTime) { return Store.timestamp(date) }
    return time?.date ?? ""
  }

  private static func event(_ raw: RawEvent) -> GoogleEvent {
    // The video link: the conference attached to the event, else a Zoom/Meet/Teams link in the
    // location or description.
    let video = raw.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
    let text = "\(raw.location ?? "") \(raw.description ?? "")"
    let found = text.range(of: meetingLink, options: [.regularExpression, .caseInsensitive]).map { String(text[$0]) }
    return GoogleEvent(
      id: raw.id, cancelled: raw.status == "cancelled", title: raw.summary ?? "(No title)", start: instant(raw.start), end: instant(raw.end),
      allDay: raw.start?.date != nil && raw.start?.dateTime == nil, joinUrl: video ?? raw.hangoutLink ?? found, htmlUrl: raw.htmlLink,
      location: raw.location, response: raw.attendees?.first { $0.isSelf == true }?.responseStatus
    )
  }

  private func get(_ path: String, client: Client, refreshToken: String) async throws -> (Data, Int) {
    var request = URLRequest(url: URL(string: "\(Self.calendarAPI)/\(path)")!)
    request.setValue("Bearer \(try await validAccessToken(client: client, refreshToken: refreshToken))", forHTTPHeaderField: "authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as! HTTPURLResponse).statusCode)
  }

  private static func failure(_ data: Data, status: Int) -> Error {
    let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
    return IntegrationError("Google Calendar \(status): \(message ?? "request failed")")
  }

  /// Every event between two instants on your primary calendar, recurring ones expanded.
  /// `showDeleted` also returns cancelled ones, which is how a deletion is told apart from a move.
  func events(from timeMin: String, to timeMax: String, showDeleted: Bool = false, client: Client, refreshToken: String) async throws -> [GoogleEvent] {
    var events: [GoogleEvent] = []
    var pageToken: String?
    repeat {
      var components = URLComponents()
      components.queryItems = [
        URLQueryItem(name: "timeMin", value: timeMin), URLQueryItem(name: "timeMax", value: timeMax),
        URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"),
        URLQueryItem(name: "maxResults", value: "2500"), URLQueryItem(name: "showDeleted", value: String(showDeleted)),
      ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
      let (data, status) = try await get("events?\(components.percentEncodedQuery!)", client: client, refreshToken: refreshToken)
      guard status == 200 else { throw Self.failure(data, status: status) }
      struct Page: Decodable { let items: [RawEvent]?; let nextPageToken: String? }
      let page = try JSONDecoder().decode(Page.self, from: data)
      events += (page.items ?? []).map(Self.event)
      pageToken = page.nextPageToken
    } while pageToken != nil
    return events
  }

  /// One event by ID; nil when Google no longer has it.
  func event(id: String, client: Client, refreshToken: String) async throws -> GoogleEvent? {
    let (data, status) = try await get(
      "events/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)", client: client, refreshToken: refreshToken
    )
    if status == 404 || status == 410 { return nil }
    guard status == 200 else { throw Self.failure(data, status: status) }
    return Self.event(try JSONDecoder().decode(RawEvent.self, from: data))
  }

  // MARK: Helpers

  private static func randomURLSafe(_ bytes: Int) -> String { OAuth.randomURLSafe(bytes) }
  private static func form(_ fields: [String: String]) -> Data { OAuth.form(fields) }
}
