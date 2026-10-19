import SwiftUI

/// Someone whose PRs the Team view can follow.
struct GitHubPerson: Identifiable, Equatable, Sendable {
  let login: String
  let name: String?
  let avatarUrl: String?
  /// The GitHub teams you share with them.
  var teams: [String] = []
  /// PRs they've opened lately in the repos you follow.
  var recentPrs = 0
  var id: String { login.lowercased() }
}

extension GitHub {
  /// Teams bigger than this are an org's everyone-team (one has half a million people), not a team.
  private static let teamSizeLimit = 50
  private static let recentDays = 30

  /// The people you're likely to want on Team: the members of your GitHub teams (small ones only)
  /// and whoever has opened PRs lately in `repos`, busiest first. You and bots are left out.
  static func likelyTeammates(token: String, repos: [String]) async throws -> [GitHubPerson] {
    let login = try await viewer(token: token)
    struct Teams: Decodable {
      struct Member: Decodable { let login: String; let name: String?; let avatarUrl: String? }
      struct Members: Decodable { let totalCount: Int; let nodes: [Member] }
      struct Team: Decodable { let name: String; let members: Members }
      struct Org: Decodable { let login: String; let teams: Nodes<Team> }
      struct Viewer: Decodable { let organizations: Nodes<Org> }
      let viewer: Viewer
    }
    var people: [GitHubPerson] = []
    func person(_ login: String) -> Int? { people.firstIndex { $0.login.caseInsensitiveCompare(login) == .orderedSame } }

    let teams = try await graphql(
      """
      query MyTeams($login: [String!]) { viewer { organizations(first: 50) { nodes { login teams(first: 20, userLogins: $login) { nodes {
        name members(first: \(teamSizeLimit)) { totalCount nodes { login name avatarUrl(size: 48) } }
      } } } } } }
      """,
      variables: ["login": [login]], token: token, as: Teams.self
    )
    for org in teams.viewer.organizations.nodes {
      for team in org.teams.nodes where team.members.totalCount <= teamSizeLimit {
        for member in team.members.nodes where member.login.caseInsensitiveCompare(login) != .orderedSame {
          if let index = person(member.login) {
            people[index].teams.append(team.name)
          } else {
            people.append(GitHubPerson(login: member.login, name: member.name, avatarUrl: member.avatarUrl, teams: [team.name]))
          }
        }
      }
    }

    // Who's been opening PRs in your repos; a failure only loses the hint.
    if !repos.isEmpty {
      struct Search: Decodable {
        struct Author: Decodable { let login: String; let avatarUrl: String? }
        struct Node: Decodable { let author: Author? }
        struct Results: Decodable { let nodes: [Node] }
        let search: Results
      }
      let since = Date(timeIntervalSinceNow: -Double(recentDays) * 86_400).formatted(.iso8601.year().month().day())
      let scope = repos.map { "repo:\($0)" }.joined(separator: " ")
      let authors = (try? await graphql(
        """
        query RecentAuthors($q: String!) { search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest {
          author { login avatarUrl(size: 48) }
        } } } }
        """,
        variables: ["q": "is:pr created:>=\(since) \(scope)"], token: token, as: Search.self
      ).search.nodes.compactMap(\.author)) ?? []
      for author in authors where author.login.caseInsensitiveCompare(login) != .orderedSame && !isBot(author.login) {
        if let index = person(author.login) {
          people[index].recentPrs += 1
        } else {
          people.append(GitHubPerson(login: author.login, name: nil, avatarUrl: author.avatarUrl, recentPrs: 1))
        }
      }
    }
    return people.sorted { ($0.teams.isEmpty ? 1 : 0, -$0.recentPrs, $0.login.lowercased()) < ($1.teams.isEmpty ? 1 : 0, -$1.recentPrs, $1.login.lowercased()) }
  }

  /// People whose login or name matches, anywhere on GitHub.
  static func searchPeople(_ term: String, token: String) async throws -> [GitHubPerson] {
    struct Search: Decodable {
      struct Node: Decodable { let login: String?; let name: String?; let avatarUrl: String? }
      struct Results: Decodable { let nodes: [Node] }
      let search: Results
    }
    return try await graphql(
      """
      query FindPeople($q: String!) { search(query: $q, type: USER, first: 20) { nodes { ... on User { login name avatarUrl(size: 48) } } } }
      """,
      variables: ["q": "\(term) type:user"], token: token, as: Search.self
    ).search.nodes.compactMap { node in node.login.map { GitHubPerson(login: $0, name: node.name, avatarUrl: node.avatarUrl) } }
  }

  private static func isBot(_ login: String) -> Bool {
    login.hasSuffix("[bot]") || ["dependabot", "renovate", "github-actions"].contains(login.lowercased()) || Derive.isCodeRabbit(login)
  }
}

/// Whose PRs the Team view follows: everyone in your repos, or the people ticked here. Suggests
/// your GitHub teammates and whoever's been opening PRs in your repos, and searches GitHub for
/// anyone else. Writes Settings → Accounts → Team (comma-separated logins, empty meaning everyone).
struct TeamPicker: View {
  @Environment(AppSettings.self) private var settings
  /// Ticks your GitHub teammates when no one is chosen yet, as on Get started.
  var preselect = false
  var listHeight: CGFloat = 220
  @State private var people: [GitHubPerson]?
  @State private var found: [GitHubPerson] = []
  @State private var searching = false
  @State private var error: String?
  @State private var search = ""

  private var chosen: [String] { AppSettings.list(settings.githubTeam) }
  private var repos: [String] { AppSettings.list(settings.githubRepos) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
        TextField("Search people by name or login", text: $search).textFieldStyle(.plain)
        if searching { ProgressView().controlSize(.small) }
        Text(chosen.isEmpty ? "Everyone" : "\(chosen.count) chosen").scaledFont(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(Palette.background, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))

      Group {
        if let error {
          Text(error).scaledFont(.callout).foregroundStyle(Tone.bad.color).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let people {
          list(people)
        } else {
          VStack(spacing: 0) { ForEach(0 ..< 4, id: \.self) { SkeletonRow(seed: $0) } }
        }
      }
      .frame(height: listHeight)

      HStack(spacing: 12) {
        Button("Follow Everyone") { settings.githubTeam = "" }
          .buttonStyle(.link).clickable(underline: true)
          .disabled(chosen.isEmpty)
        if let people, people.contains(where: { !$0.teams.isEmpty }) {
          Button("Choose My Teammates") { settings.githubTeam = people.filter { !$0.teams.isEmpty }.map(\.login).joined(separator: ", ") }
            .buttonStyle(.link).clickable(underline: true)
        }
        Spacer()
      }
      .scaledFont(.caption)
      Text(footnote).scaledFont(.caption).foregroundStyle(chosen.isEmpty && repos.isEmpty ? Tone.warn.color : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .task(id: "\(settings.githubCredential)|\(settings.githubRepos)") { await load() }
    .task(id: search) { await find() }
  }

  private var footnote: String {
    if !chosen.isEmpty { return "Team shows PRs by these people\(repos.isEmpty ? "" : " in your repos")." }
    if repos.isEmpty { return "With no one chosen, Team shows everyone's PRs in your repos, so it needs repos chosen first, or some people here." }
    return "With no one chosen, Team shows everyone's PRs in your repos, apart from yours and bots'."
  }

  private func list(_ people: [GitHubPerson]) -> some View {
    let query = search.trimmingCharacters(in: .whitespaces)
    var all = people
    for login in chosen where !all.contains(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }) {
      all.append(GitHubPerson(login: login, name: nil, avatarUrl: "https://github.com/\(login).png?size=48"))
    }
    for person in found where !all.contains(where: { $0.id == person.id }) { all.append(person) }
    let shown = all
      .filter { query.isEmpty || $0.login.localizedCaseInsensitiveContains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query) }
      .sorted { (isChosen($0) ? 0 : 1) < (isChosen($1) ? 0 : 1) }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(shown) { row($0) }
        if shown.isEmpty {
          Text(query.isEmpty ? "No teammates found yet. Search to add someone." : searching ? "Searching…" : "No one matches “\(query)”.")
            .scaledFont(.callout).foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
        }
      }
    }
    .background(Palette.background, in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
  }

  private func row(_ person: GitHubPerson) -> some View {
    let on = isChosen(person)
    return Button { toggle(person) } label: {
      HStack(spacing: 10) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .scaledFont(.body)
          .foregroundStyle(on ? AnyShapeStyle(Color.workbenchAccent) : AnyShapeStyle(.tertiary))
        AvatarView(url: person.avatarUrl, size: 22)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(person.name ?? person.login).scaledFont(.callout.weight(.medium)).lineLimit(1)
            if person.name != nil { Text(person.login).scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1) }
          }
          if !person.teams.isEmpty {
            Text(person.teams.joined(separator: ", ")).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if person.recentPrs > 0 {
          Text("\(person.recentPrs) PR\(person.recentPrs == 1 ? "" : "s") lately").scaledFont(.caption).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .clickable()
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  private func isChosen(_ person: GitHubPerson) -> Bool {
    chosen.contains { $0.caseInsensitiveCompare(person.login) == .orderedSame }
  }

  private func toggle(_ person: GitHubPerson) {
    var next = chosen
    if isChosen(person) {
      next.removeAll { $0.caseInsensitiveCompare(person.login) == .orderedSame }
    } else {
      next.append(person.login)
    }
    settings.githubTeam = next.joined(separator: ", ")
  }

  private func load() async {
    guard settings.hasGitHub else { return }
    error = nil
    do {
      let loaded = try await GitHub.likelyTeammates(token: settings.githubCredential, repos: repos)
      people = loaded
      if preselect && chosen.isEmpty {
        let teammates = loaded.filter { !$0.teams.isEmpty }.map(\.login)
        if !teammates.isEmpty { settings.githubTeam = teammates.joined(separator: ", ") }
      }
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Looks across GitHub once you've typed a little, after a pause.
  private func find() async {
    let term = search.trimmingCharacters(in: .whitespaces)
    guard term.count >= 2, settings.hasGitHub else { found = []; return }
    try? await Task.sleep(for: .milliseconds(350))
    guard !Task.isCancelled else { return }
    searching = true
    defer { searching = false }
    found = (try? await GitHub.searchPeople(term, token: settings.githubCredential)) ?? []
  }
}

/// Settings → Accounts: the people picker in a sheet, beside the Team field.
struct ChooseTeamButton: View {
  @State private var open = false

  var body: some View {
    Button("Choose…") { open = true }
      .clickable()
      .sheet(isPresented: $open) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Whose PRs Team shows").scaledFont(.headline)
          TeamPicker(listHeight: 320)
          HStack {
            Spacer()
            Button("Done") { open = false }.keyboardShortcut(.defaultAction).clickable()
          }
        }
        .padding(20)
        .scaledFrame(width: 520)
        .workbenchPage()
      }
  }
}
