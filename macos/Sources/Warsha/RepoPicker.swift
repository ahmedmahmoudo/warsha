import SwiftUI

/// A repo the GitHub account can read, for choosing which ones Warsha follows.
struct GitHubRepo: Identifiable, Equatable, Sendable {
  let nameWithOwner: String
  let isPrivate: Bool
  let description: String?
  let pushedAt: Date?
  /// You've opened a PR in it lately: most likely one you work in.
  var active = false
  var id: String { nameWithOwner }
  var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
}

extension GitHub {
  private static let activeDays = 90

  /// The repos you're likely to want, without the thousands a big org can expose: the ones you've
  /// opened PRs in lately (marked active), the ones you've contributed to, and your own and
  /// collaborator repos. Anything else is found with `searchRepos`. Also returns your orgs, which
  /// that search covers.
  static func likelyRepos(token: String) async throws -> (repos: [GitHubRepo], login: String, orgs: [String]) {
    struct Result: Decodable {
      struct Node: Decodable { let nameWithOwner: String; let isPrivate: Bool; let description: String?; let pushedAt: String? }
      struct Repos: Decodable { let nodes: [Node] }
      struct Org: Decodable { let login: String }
      struct Viewer: Decodable {
        let login: String
        let organizations: Nodes<Org>
        let repositoriesContributedTo: Repos
        let repositories: Repos
      }
      let viewer: Viewer
    }
    let fields = "nodes { nameWithOwner isPrivate description pushedAt }"
    let viewer = try await graphql(
      """
      query LikelyRepos { viewer {
        login
        organizations(first: 100) { nodes { login } }
        repositoriesContributedTo(first: 100, includeUserRepositories: true,
          contributionTypes: [COMMIT, PULL_REQUEST, PULL_REQUEST_REVIEW], orderBy: { field: PUSHED_AT, direction: DESC }) { \(fields) }
        repositories(first: 100, isArchived: false, affiliations: [OWNER, COLLABORATOR], ownerAffiliations: [OWNER, COLLABORATOR],
          orderBy: { field: PUSHED_AT, direction: DESC }) { \(fields) }
      } }
      """,
      token: token, as: Result.self
    ).viewer

    var repos: [GitHubRepo] = []
    func add(_ node: Result.Node) {
      guard !repos.contains(where: { $0.nameWithOwner.caseInsensitiveCompare(node.nameWithOwner) == .orderedSame }) else { return }
      repos.append(GitHubRepo(nameWithOwner: node.nameWithOwner, isPrivate: node.isPrivate, description: node.description,
                              pushedAt: node.pushedAt.flatMap { try? Date($0, strategy: .iso8601) }))
    }
    viewer.repositoriesContributedTo.nodes.forEach(add)
    viewer.repositories.nodes.forEach(add)

    // Where you've opened PRs lately; a failure here only loses the hint.
    struct Search: Decodable {
      struct Results: Decodable { let nodes: [Node] }
      struct Node: Decodable { struct Repo: Decodable { let nameWithOwner: String; let isPrivate: Bool; let description: String?; let pushedAt: String? }; let repository: Repo? }
      let search: Results
    }
    let since = Date(timeIntervalSinceNow: -Double(activeDays) * 86_400).formatted(.iso8601.year().month().day())
    let recent = (try? await graphql(
      """
      query Active($q: String!) { search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest {
        repository { nameWithOwner isPrivate description pushedAt }
      } } } }
      """,
      variables: ["q": "is:pr author:\(viewer.login) created:>=\(since)"], token: token, as: Search.self
    ).search.nodes.compactMap(\.repository)) ?? []
    for repo in recent { add(Result.Node(nameWithOwner: repo.nameWithOwner, isPrivate: repo.isPrivate, description: repo.description, pushedAt: repo.pushedAt)) }
    let active = Set(recent.map { $0.nameWithOwner.lowercased() })
    for index in repos.indices where active.contains(repos[index].nameWithOwner.lowercased()) { repos[index].active = true }
    return (repos, viewer.login, viewer.organizations.nodes.map(\.login))
  }

  /// Repos whose name matches, in your own account and your orgs only.
  static func searchRepos(_ term: String, owners: [String], token: String) async throws -> [GitHubRepo] {
    struct Search: Decodable {
      struct Results: Decodable { let nodes: [Node] }
      struct Node: Decodable { let nameWithOwner: String?; let isPrivate: Bool?; let description: String?; let pushedAt: String? }
      let search: Results
    }
    let scope = owners.map { "user:\($0)" }.joined(separator: " ")
    return try await graphql(
      """
      query FindRepos($q: String!) { search(query: $q, type: REPOSITORY, first: 30) { nodes { ... on Repository {
        nameWithOwner isPrivate description pushedAt
      } } } }
      """,
      variables: ["q": "\(term) in:name archived:false fork:true \(scope)"], token: token, as: Search.self
    ).search.nodes.compactMap { node in
      node.nameWithOwner.map {
        GitHubRepo(nameWithOwner: $0, isPrivate: node.isPrivate ?? false, description: node.description,
                   pushedAt: node.pushedAt.flatMap { try? Date($0, strategy: .iso8601) })
      }
    }
  }
}

/// Which repos Warsha follows: all you can see, or the ones ticked here. Lists the repos you're
/// likely to want (worked in lately, contributed to, your own) and searches your account and orgs
/// for the rest; the ones you've opened PRs in lately come first and are suggested. Writes
/// Settings → Accounts → Repos (comma-separated, empty meaning all).
struct RepoPicker: View {
  @Environment(AppSettings.self) private var settings
  /// Ticks the suggested repos when none are chosen yet, as on Get started.
  var preselect = false
  var listHeight: CGFloat = 220
  @State private var repos: [GitHubRepo]?
  /// Your login and orgs, which the search for other repos covers.
  @State private var owners: [String] = []
  @State private var found: [GitHubRepo] = []
  @State private var searching = false
  @State private var error: String?
  @State private var search = ""

  private var chosen: [String] { AppSettings.list(settings.githubRepos) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
        TextField("Search repos", text: $search).textFieldStyle(.plain)
        if let repos {
          if searching { ProgressView().controlSize(.small) }
          Text(chosen.isEmpty ? "Following all" : "\(chosen.count) chosen").scaledFont(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(Palette.background, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))

      Group {
        if let error {
          Text(error).scaledFont(.callout).foregroundStyle(Tone.bad.color).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let repos {
          list(repos)
        } else {
          VStack(spacing: 0) { ForEach(0 ..< 4, id: \.self) { SkeletonRow(seed: $0) } }
        }
      }
      .frame(height: listHeight)

      HStack(spacing: 12) {
        Button("Follow All Repos") { settings.githubRepos = "" }
          .buttonStyle(.link).clickable(underline: true)
          .disabled(chosen.isEmpty)
        if let repos, repos.contains(where: \.active) {
          Button("Choose the Ones I Work In") { settings.githubRepos = repos.filter(\.active).map(\.nameWithOwner).joined(separator: ", ") }
            .buttonStyle(.link).clickable(underline: true)
        }
        Spacer()
      }
      .scaledFont(.caption)
      Text(chosen.isEmpty
        ? "Warsha follows every repo you can see. Choosing some keeps Pull Requests and Team to just those."
        : "Pull Requests and Team show PRs from these repos only.")
        .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .task(id: settings.githubCredential) { await load() }
    .task(id: search) { await find() }
  }

  private func list(_ repos: [GitHubRepo]) -> some View {
    let query = search.trimmingCharacters(in: .whitespaces)
    // Chosen repos stay listed even when they're not among the likely ones.
    var all = repos
    for name in chosen where !all.contains(where: { $0.nameWithOwner.caseInsensitiveCompare(name) == .orderedSame }) {
      all.append(GitHubRepo(nameWithOwner: name, isPrivate: false, description: nil, pushedAt: nil))
    }
    for repo in found where !all.contains(where: { $0.nameWithOwner.caseInsensitiveCompare(repo.nameWithOwner) == .orderedSame }) {
      all.append(repo)
    }
    let shown = all
      .filter { query.isEmpty || $0.nameWithOwner.localizedCaseInsensitiveContains(query) || ($0.description ?? "").localizedCaseInsensitiveContains(query) }
      .sorted { ($0.active ? 0 : 1, isChosen($0) ? 0 : 1) < ($1.active ? 0 : 1, isChosen($1) ? 0 : 1) }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(shown) { repo in row(repo) }
        if shown.isEmpty {
          Text(query.isEmpty ? "No repos you've worked in yet. Search to find one." : searching ? "Searching…" : "No repo matches “\(query)” in your account or orgs.")
            .scaledFont(.callout).foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
        }
      }
    }
    .background(Palette.background, in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
  }

  private func row(_ repo: GitHubRepo) -> some View {
    let on = isChosen(repo)
    return Button { toggle(repo) } label: {
      HStack(spacing: 10) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .scaledFont(.body)
          .foregroundStyle(on ? AnyShapeStyle(Color.warshaAccent) : AnyShapeStyle(.tertiary))
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(repo.nameWithOwner).scaledFont(.callout.weight(.medium)).lineLimit(1)
            if repo.isPrivate { Image(systemName: "lock.fill").scaledFont(.caption2).foregroundStyle(.tertiary) }
            if repo.active { Chip(text: "You work here", tone: .good) }
          }
          if let description = repo.description, !description.isEmpty {
            Text(description).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if let pushed = repo.pushedAt {
          Text(pushed, format: .relative(presentation: .named)).scaledFont(.caption).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .clickable()
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  private func isChosen(_ repo: GitHubRepo) -> Bool {
    chosen.contains { $0.caseInsensitiveCompare(repo.nameWithOwner) == .orderedSame }
  }

  private func toggle(_ repo: GitHubRepo) {
    var next = chosen
    if isChosen(repo) {
      next.removeAll { $0.caseInsensitiveCompare(repo.nameWithOwner) == .orderedSame }
    } else {
      next.append(repo.nameWithOwner)
    }
    settings.githubRepos = next.joined(separator: ", ")
  }

  private func load() async {
    guard settings.hasGitHub else { return }
    error = nil
    do {
      let likely = try await GitHub.likelyRepos(token: settings.githubCredential)
      let loaded = likely.repos
      repos = loaded
      owners = [likely.login] + likely.orgs
      if preselect && chosen.isEmpty {
        let active = loaded.filter(\.active).map(\.nameWithOwner)
        if !active.isEmpty { settings.githubRepos = active.joined(separator: ", ") }
      }
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }
}

extension RepoPicker {
  /// Looks further than the likely repos once you've typed a little, after a pause.
  fileprivate func find() async {
    let term = search.trimmingCharacters(in: .whitespaces)
    guard term.count >= 2, !owners.isEmpty else { found = []; return }
    try? await Task.sleep(for: .milliseconds(350))
    guard !Task.isCancelled else { return }
    searching = true
    defer { searching = false }
    found = (try? await GitHub.searchRepos(term, owners: owners, token: settings.githubCredential)) ?? []
  }
}

/// Settings → Accounts: the repo picker in a sheet, beside the text field.
struct ChooseReposButton: View {
  @State private var open = false

  var body: some View {
    Button("Choose…") { open = true }
      .clickable()
      .sheet(isPresented: $open) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Repos to follow").scaledFont(.headline)
          RepoPicker(listHeight: 320)
          HStack {
            Spacer()
            Button("Done") { open = false }.keyboardShortcut(.defaultAction).clickable()
          }
        }
        .padding(20)
        .scaledFrame(width: 520)
        .warshaPage()
      }
  }
}
