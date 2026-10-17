import Foundation

/// The credentials and preferences a load needs, copied off the main actor.
struct PrConfig: Sendable, Hashable {
  let githubToken: String
  let linearApiKey: String
  let githubRepos: [String]
  let githubTeam: [String]

  nonisolated init(githubToken: String, linearApiKey: String, githubRepos: [String], githubTeam: [String]) {
    self.githubToken = githubToken
    self.linearApiKey = linearApiKey
    self.githubRepos = githubRepos
    self.githubTeam = githubTeam
  }

  @MainActor
  init(_ settings: AppSettings) {
    self.init(
      githubToken: settings.githubToken, linearApiKey: settings.linearApiKey,
      githubRepos: AppSettings.list(settings.githubRepos), githubTeam: AppSettings.list(settings.githubTeam)
    )
  }
}

/// Builds the Pull Requests list: server/prs/route.ts and reviewContext.ts in Swift. Concurrent
/// loads of one scope share a single request, and CODEOWNERS, teams, the viewer and the token
/// check are kept between loads.
actor PrService {
  static let shared = PrService()

  private static let mergedLookbackDays = 7
  private static let reviewedLookbackDays = 14
  /// CODEOWNERS and team lists change rarely; re-read them every so often.
  private static let codeownersMaxAge: TimeInterval = 10 * 60

  private var inflight: [PrScope: (config: PrConfig, task: Task<PrsResponse, any Error>)] = [:]
  private var viewers: [String: String] = [:]
  private var tokenChecks: [PrConfig: Task<[String], Never>] = [:]
  private var codeowners: [String: (at: Date, value: Codeowners?)] = [:]
  private var teams: [String: (at: Date, value: [String: Person])] = [:]

  func load(_ scope: PrScope, config: PrConfig) async throws -> PrsResponse {
    if let running = inflight[scope], running.config == config { return try await running.task.value }
    let task = Task { try await build(scope, config: config) }
    inflight[scope] = (config, task)
    defer { if inflight[scope]?.task == task { inflight[scope] = nil } }
    return try await task.value
  }

  private func build(_ scope: PrScope, config: PrConfig) async throws -> PrsResponse {
    let viewer = try await viewer(config.githubToken)
    let queries = try Self.searchQueries(scope, login: viewer, config: config)
    async let openResults = searchAll(queries.open, token: config.githubToken)
    async let mergedResults = searchAll(queries.merged, token: config.githubToken)
    let (open, merged) = try await (openResults, mergedResults)
    let reviews = await reviewContexts(open.prs, token: config.githubToken)

    var warnings = await tokenProblems(config)
    if open.truncated || merged.truncated { warnings.append("Some results were cut off at the page limit.") }

    var keys: [String] = []
    for key in (open.prs + merged.prs).flatMap(Derive.ticketKeys) where !keys.contains(key) { keys.append(key) }
    var tickets: [String: Ticket]?
    do {
      tickets = try await Linear.tickets(keys, apiKey: config.linearApiKey)
    } catch let error as NotConfigured {
      warnings.append("Linear: \(error.localizedDescription)")
    } catch {
      warnings.append("Linear lookup failed: \(error.localizedDescription)")
    }

    return PrsResponse(
      scope: scope,
      viewer: viewer,
      open: Derive.linkStacks(open.prs.map { Derive.pr($0, tickets: tickets, review: reviews[$0.url]) })
        .sorted { $0.updatedAt > $1.updatedAt },
      recentlyMerged: merged.prs.map { Derive.pr($0, tickets: tickets) }
        .sorted { ($0.mergedAt ?? "") > ($1.mergedAt ?? "") },
      fetchedAt: Date(),
      warnings: warnings
    )
  }

  private static func daysAgo(_ days: Int) -> String {
    String(Store.timestamp(Date(timeIntervalSinceNow: -Double(days) * 86_400)).prefix(10))
  }

  static func searchQueries(_ scope: PrScope, login: String, config: PrConfig) throws -> (open: [String], merged: [String]) {
    let repos = config.githubRepos.map { "repo:\($0)" }.joined(separator: " ")
    let mergedSince = "merged:>=\(daysAgo(mergedLookbackDays))"
    switch scope {
    case .mine:
      return (["is:pr is:open archived:false author:\(login)"], ["is:pr is:merged author:\(login) \(mergedSince)"])
    case .reviewing:
      // Only requests made to you personally (not via a CODEOWNERS team); a request disappears
      // once you review, so recently reviewed PRs stay visible too.
      return (
        [
          "is:pr is:open archived:false user-review-requested:\(login)",
          "is:pr is:open archived:false reviewed-by:\(login) -author:\(login) updated:>=\(daysAgo(reviewedLookbackDays))",
        ],
        ["is:pr is:merged reviewed-by:\(login) -author:\(login) \(mergedSince)"]
      )
    case .team:
      guard !config.githubTeam.isEmpty else { throw NotConfigured("Add your team's GitHub logins in Settings → Accounts.") }
      let authors = config.githubTeam.map { "author:\($0)" }.joined(separator: " ")
      return (["is:pr is:open archived:false \(authors) \(repos)"], ["is:pr is:merged \(authors) \(repos) \(mergedSince)"])
    }
  }

  private func searchAll(_ queries: [String], token: String) async throws -> (prs: [GithubPr], truncated: Bool) {
    let results = try await withThrowingTaskGroup(of: (prs: [GithubPr], truncated: Bool).self) { group in
      for query in queries { group.addTask { try await GitHub.searchPrs(query, token: token) } }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    var byUrl: [String: GithubPr] = [:]
    for pr in results.flatMap(\.prs) { byUrl[pr.url] = pr }
    return (Array(byUrl.values), results.contains { $0.truncated })
  }

  private func viewer(_ token: String) async throws -> String {
    if let known = viewers[token] { return known }
    let login = try await GitHub.viewer(token: token)
    viewers[token] = login
    return login
  }

  /// Checked once per token and repo list, like the web version's startup check.
  private func tokenProblems(_ config: PrConfig) async -> [String] {
    if let running = tokenChecks[config] { return await running.value }
    let task = Task { await GitHub.tokenProblems(token: config.githubToken, repos: config.githubRepos) }
    tokenChecks[config] = task
    return await task.value
  }

  /// CODEOWNERS for each base branch and every changed file, so each PR's review gate can name the
  /// owners still to approve. A failure here only makes that gate incomplete.
  private func reviewContexts(_ prs: [GithubPr], token: String) async -> [String: Derive.ReviewContext] {
    var contexts: [String: Derive.ReviewContext] = [:]
    for pr in prs {
      let owners = await codeownersFor(repo: pr.repository.nameWithOwner, branch: pr.baseRefName, token: token)
      contexts[pr.url] = Derive.ReviewContext(
        codeowners: owners, files: pr.files.nodes.map(\.path), filesComplete: true,
        teams: await teamsFor(org: String(pr.repository.nameWithOwner.split(separator: "/")[0]), token: token)
      )
    }
    // More than 100 changed files: fetch the rest in parallel.
    let longer = prs.filter { $0.files.pageInfo.hasNextPage && $0.files.pageInfo.endCursor != nil }
    await withTaskGroup(of: (String, [String]?).self) { group in
      for pr in longer {
        group.addTask { (pr.url, try? await GitHub.remainingFiles(prId: pr.id, after: pr.files.pageInfo.endCursor!, token: token)) }
      }
      for await (url, rest) in group {
        guard let context = contexts[url] else { continue }
        contexts[url] = Derive.ReviewContext(
          codeowners: context.codeowners, files: context.files + (rest ?? []), filesComplete: rest != nil, teams: context.teams
        )
      }
    }
    return contexts
  }

  private func codeownersFor(repo: String, branch: String, token: String) async -> Codeowners? {
    let key = "\(repo)\0\(branch)"
    if let cached = codeowners[key], -cached.at.timeIntervalSinceNow < Self.codeownersMaxAge { return cached.value }
    do {
      let value = try await GitHub.codeownersText(repo: repo, branch: branch, token: token).map(Codeowners.init)
      codeowners[key] = (Date(), value)
      return value
    } catch {
      return codeowners[key]?.value
    }
  }

  /// Teams only make code owners look nicer, so failing to list them (no read:org) leaves slugs.
  /// The failure is kept like a result, so it isn't retried for every PR.
  private func teamsFor(org: String, token: String) async -> [String: Person] {
    if let cached = teams[org], -cached.at.timeIntervalSinceNow < Self.codeownersMaxAge { return cached.value }
    let list = (try? await GitHub.orgTeams(org, token: token)) ?? []
    var value: [String: Person] = [:]
    for team in list {
      value["\(org)/\(team.slug)".lowercased()] = Person(
        kind: .team, id: "\(org)/\(team.slug)", name: team.name, avatarUrl: team.avatarUrl,
        url: "https://github.com/orgs/\(org)/teams/\(team.slug)"
      )
    }
    teams[org] = (Date(), value)
    return value
  }
}
