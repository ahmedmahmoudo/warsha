import AppKit

/// What the web version read from .env.local: secrets in the Keychain, the rest in UserDefaults.
/// A blank value means "not configured", so each integration can say what's missing.
@MainActor
@Observable
final class AppSettings {
  var githubToken: String { didSet { saveSecret("githubToken", githubToken) } }
  var linearApiKey: String { didSet { saveSecret("linearApiKey", linearApiKey) } }
  var googleClientSecret: String { didSet { saveSecret("googleClientSecret", googleClientSecret) } }

  /// Comma-separated repos to search; empty searches every repo you can see.
  var githubRepos: String { didSet { save(githubRepos, "githubRepos") } }
  /// Comma-separated GitHub logins whose PRs the Team view shows.
  var githubTeam: String { didSet { save(githubTeam, "githubTeam") } }
  /// OAuth Desktop client for Google Calendar.
  var googleClientId: String { didSet { save(googleClientId, "googleClientId") } }
  /// Comma-separated owner/repo=/path pairs for where repos are cloned on this Mac.
  var localRepos: String { didSet { save(localRepos, "localRepos") } }
  /// Your home zone: where Today's and Activity's days start, and the Calendar's first zone.
  /// This Mac's zone unless changed in Settings.
  var timeZone: String { didSet { save(timeZone, "timeZone") } }
  /// Comma-separated ticket states that are fine once a PR has merged (besides done and canceled),
  /// for teams that move tickets to, say, "Merged" until they ship.
  var afterMergeStates: String { didSet { save(afterMergeStates, "afterMergeStates") } }
  /// How long a PR counts as new, to send to the team for review rather than nudge (hours).
  var newPrHours: Int { didSet { defaults.set(newPrHours, forKey: "newPrHours") } }
  /// How long after sending or nudging before Today suggests a nudge again (hours).
  var nudgeAgainHours: Int { didSet { defaults.set(nudgeAgainHours, forKey: "nudgeAgainHours") } }
  /// Text size across the app, 1 being macOS's own (View → Zoom In, Zoom Out, Actual Size).
  var textScale: Double { didSet { defaults.set(textScale, forKey: "textScale") } }
  /// Light, dark, or whatever macOS is set to, like the web version's theme switch.
  var appearance: Appearance {
    didSet {
      save(appearance.rawValue, "appearance")
      applyAppearance()
    }
  }

  enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var label: String {
      switch self {
      case .system: "System"
      case .light: "Light"
      case .dark: "Dark"
      }
    }
  }

  @ObservationIgnored private let defaults = UserDefaults.standard
  /// False when the settings came from a file for this launch only (`-WorkbenchEnvFile`): nothing
  /// is saved, and the Keychain isn't touched.
  @ObservationIgnored private var persists = true

  init() {
    githubToken = ""
    linearApiKey = ""
    googleClientSecret = ""
    githubRepos = ""
    githubTeam = ""
    googleClientId = ""
    localRepos = ""
    timeZone = TimeZone.current.identifier
    afterMergeStates = "Merged"
    newPrHours = 24
    nudgeAgainHours = 24
    textScale = defaults.object(forKey: "textScale") == nil ? 1 : defaults.double(forKey: "textScale")
    appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
    if let file = DevHooks.envFile {
      persists = false
      _ = try? importEnvFile(URL(fileURLWithPath: file))
      return
    }
    if DevHooks.isHostingTests {
      persists = false
      return
    }
    githubToken = Keychain.get("githubToken") ?? ""
    linearApiKey = Keychain.get("linearApiKey") ?? ""
    googleClientSecret = Keychain.get("googleClientSecret") ?? ""
    githubRepos = defaults.string(forKey: "githubRepos") ?? ""
    githubTeam = defaults.string(forKey: "githubTeam") ?? ""
    googleClientId = defaults.string(forKey: "googleClientId") ?? ""
    localRepos = defaults.string(forKey: "localRepos") ?? ""
    timeZone = defaults.string(forKey: "timeZone") ?? TimeZone.current.identifier
    afterMergeStates = defaults.string(forKey: "afterMergeStates") ?? "Merged"
    newPrHours = defaults.object(forKey: "newPrHours") as? Int ?? 24
    nudgeAgainHours = defaults.object(forKey: "nudgeAgainHours") as? Int ?? 24
  }

  /// Sets every window's appearance; nil follows macOS, switching live when it changes.
  func applyAppearance() {
    NSApp.appearance = switch appearance {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  private func saveSecret(_ key: String, _ value: String) {
    if persists { Keychain.set(key, value) }
  }

  private func save(_ value: String, _ key: String) {
    if persists { defaults.set(value, forKey: key) }
  }

  nonisolated static func list(_ value: String) -> [String] {
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
