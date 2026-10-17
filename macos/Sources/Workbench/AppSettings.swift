import Foundation

/// What the web version read from .env.local: secrets in the Keychain, the rest in UserDefaults.
/// A blank value means "not configured", so each integration can say what's missing.
@MainActor
@Observable
final class AppSettings {
  var githubToken: String { didSet { Keychain.set("githubToken", githubToken) } }
  var linearApiKey: String { didSet { Keychain.set("linearApiKey", linearApiKey) } }
  var googleClientSecret: String { didSet { Keychain.set("googleClientSecret", googleClientSecret) } }

  /// Comma-separated repos to search; empty searches every repo you can see.
  var githubRepos: String { didSet { defaults.set(githubRepos, forKey: "githubRepos") } }
  /// Comma-separated GitHub logins whose PRs the Team view shows.
  var githubTeam: String { didSet { defaults.set(githubTeam, forKey: "githubTeam") } }
  /// OAuth Desktop client for Google Calendar.
  var googleClientId: String { didSet { defaults.set(googleClientId, forKey: "googleClientId") } }
  /// Comma-separated owner/repo=/path pairs for where repos are cloned on this Mac.
  var localRepos: String { didSet { defaults.set(localRepos, forKey: "localRepos") } }
  /// Where Activity's days and weeks start.
  var timeZone: String { didSet { defaults.set(timeZone, forKey: "timeZone") } }

  @ObservationIgnored private let defaults = UserDefaults.standard

  init() {
    githubToken = Keychain.get("githubToken") ?? ""
    linearApiKey = Keychain.get("linearApiKey") ?? ""
    googleClientSecret = Keychain.get("googleClientSecret") ?? ""
    githubRepos = defaults.string(forKey: "githubRepos") ?? ""
    githubTeam = defaults.string(forKey: "githubTeam") ?? ""
    googleClientId = defaults.string(forKey: "googleClientId") ?? ""
    localRepos = defaults.string(forKey: "localRepos") ?? ""
    timeZone = defaults.string(forKey: "timeZone") ?? "Australia/Sydney"
  }

  static func list(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// Fills everything in from the web version's .env.local; keys it doesn't set are left alone.
  /// Returns the keys it used.
  @discardableResult
  func importEnvFile(_ url: URL) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let line = line.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !value.isEmpty { values[String(line[..<equals])] = value }
    }
    let fields: [(String, ReferenceWritableKeyPath<AppSettings, String>)] = [
      ("GITHUB_TOKEN", \.githubToken),
      ("GITHUB_REPOS", \.githubRepos),
      ("GITHUB_TEAM", \.githubTeam),
      ("LINEAR_API_KEY", \.linearApiKey),
      ("GOOGLE_CLIENT_ID", \.googleClientId),
      ("GOOGLE_CLIENT_SECRET", \.googleClientSecret),
      ("LOCAL_REPOS", \.localRepos),
      ("TIMEZONE", \.timeZone),
    ]
    return fields.compactMap { key, field in
      guard let value = values[key] else { return nil }
      self[keyPath: field] = value
      return key
    }
  }

  /// The token the gh CLI is signed in with, which has the scopes Workbench needs.
  static func ghToken() async -> String? {
    await Task.detached {
      let shell = Process()
      shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
      // A login shell, so Homebrew's gh is on the PATH.
      shell.arguments = ["-lc", "gh auth token"]
      let output = Pipe()
      shell.standardOutput = output
      shell.standardError = FileHandle.nullDevice
      guard (try? shell.run()) != nil else { return nil }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      shell.waitUntilExit()
      let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      return shell.terminationStatus == 0 && !token.isEmpty ? token : nil
    }.value
  }
}
