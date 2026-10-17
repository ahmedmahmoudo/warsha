import Foundation
import os

/// Failures that only make part of a page less complete, for Console (subsystem com.workbench.app).
let log = Logger(subsystem: "com.workbench.app", category: "github")

/// The credentials and preferences a load needs, copied off the main actor.
struct PrConfig: Sendable, Hashable {
  let githubToken: String
  let linearApiKey: String
  let githubRepos: [String]
  let githubTeam: [String]
  /// Where repos are cloned on this Mac, keyed by lower-case "owner/repo".
  let localRepos: [String: String]
  /// Lower-case ticket states that are fine once a PR has merged, besides done and canceled.
  let afterMerge: Set<String>

  nonisolated init(
    githubToken: String, linearApiKey: String, githubRepos: [String], githubTeam: [String], localRepos: [String: String] = [:],
    afterMerge: Set<String> = ["merged"]
  ) {
    self.githubToken = githubToken
    self.linearApiKey = linearApiKey
    self.githubRepos = githubRepos
    self.githubTeam = githubTeam
    self.localRepos = localRepos
    self.afterMerge = afterMerge
  }

  @MainActor
  init(_ settings: AppSettings) {
    var localRepos: [String: String] = [:]
    for pair in AppSettings.list(settings.localRepos) {
      let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { localRepos[parts[0].lowercased()] = parts[1] }
    }
    self.init(
      githubToken: settings.githubCredential, linearApiKey: settings.linearAuthorization,
      githubRepos: AppSettings.list(settings.githubRepos), githubTeam: AppSettings.list(settings.githubTeam),
      localRepos: localRepos, afterMerge: Set(AppSettings.list(settings.afterMergeStates).map { $0.lowercased() })
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

  /// The last answer per scope, for callers happy with a recent one.
  private var recent: [PrScope: (config: PrConfig, response: PrsResponse)] = [:]

  /// `maxAge` takes a recent answer when there is one, as Today does with the lists it's built from.
  func load(_ scope: PrScope, config: PrConfig, maxAge: TimeInterval? = nil) async throws -> PrsResponse {
    if let maxAge, let last = recent[scope], last.config == config, -last.response.fetchedAt.timeIntervalSinceNow < maxAge {
      return last.response
    }
    if let running = inflight[scope], running.config == config { return try await running.task.value }
    let task = Task { try await build(scope, config: config) }
    inflight[scope] = (config, task)
    defer { if inflight[scope]?.task == task { inflight[scope] = nil } }
    let response = try await task.value
    recent[scope] = (config, response)
    return response
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
      open: Derive.linkStacks(open.prs.map { Derive.pr($0, tickets: tickets, review: reviews[$0.url], afterMerge: config.afterMerge) })
        .sorted { $0.updatedAt > $1.updatedAt },
      recentlyMerged: merged.prs.map { Derive.pr($0, tickets: tickets, afterMerge: config.afterMerge) }
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

  // MARK: Details

  /// One PR with everything the details page shows.
  func detail(_ key: PrKey, config: PrConfig) async throws -> PrDetail {
    guard let raw = try await GitHub.prDetail(key, token: config.githubToken) else {
      throw IntegrationError("\(key.repo)#\(key.number) wasn't found, or the GitHub token can't see it")
    }
    let tickets = try? await Linear.tickets(Derive.ticketKeys(raw.base), apiKey: config.linearApiKey)
    let reviews = raw.state == "OPEN" ? await reviewContexts([raw.base], token: config.githubToken) : [:]
    let actions = await actions(raw, key: key, config: config)
    return BuildDetail.detail(raw, pr: Derive.pr(raw.base, tickets: tickets, review: reviews[raw.base.url], afterMerge: config.afterMerge), actions: actions)
  }

  /// What can be done about the branch: hand conflicts to Claude, or bring it up to date.
  private func actions(_ raw: GithubPrDetail, key: PrKey, config: PrConfig) async -> PrActions {
    guard raw.state == "OPEN" else { return PrActions() }
    let conflicted = raw.mergeable == "CONFLICTING" || raw.base.mergeStateStatus == "DIRTY"
    let pr = ClaudeHandoff.ConflictPr(
      repo: key.repo, number: raw.base.number, title: raw.base.title, url: raw.base.url, head: raw.base.headRefName, base: raw.base.baseRefName
    )
    async let conflicts = conflicted ? ClaudeHandoff.conflictAction(pr, localRepos: config.localRepos) : nil
    async let comparison = Self.comparison(key, raw, token: config.githubToken)
    let behindBy = await comparison?.behindBy ?? 0
    return PrActions(
      conflicts: await conflicts,
      updateBranch: behindBy > 0
        ? PrActions.UpdateBranch(
          behindBy: behindBy, base: raw.base.baseRefName, canUpdate: raw.viewerCanUpdateBranch && !conflicted,
          reason: conflicted ? "Resolve the conflicts first; GitHub can only update a branch that merges cleanly"
            : raw.viewerCanUpdateBranch ? nil : "GitHub won't update this branch with your token (no permission, or it's from a fork)",
          headOid: raw.headRefOid
        )
        : nil
    )
  }

  private static func comparison(_ key: PrKey, _ raw: GithubPrDetail, token: String) async -> (aheadBy: Int, behindBy: Int)? {
    do {
      return try await GitHub.branchComparison(repo: key.repo, base: raw.base.baseRefName, head: raw.base.headRefName, token: token)
    } catch {
      log.error("Couldn't compare \(raw.base.headRefName, privacy: .public) with \(raw.base.baseRefName, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Straight from GitHub every time: this is what the page polls while CI runs.
  func checks(_ key: PrKey, config: PrConfig) async throws -> PrChecks {
    guard let raw = try await GitHub.prChecks(key, token: config.githubToken) else {
      throw IntegrationError("\(key.repo)#\(key.number) wasn't found")
    }
    return PrChecks(
      headOid: raw.headRefOid, checks: Derive.checks(commits: raw.commits, mergedAt: raw.mergedAt, baseRef: raw.baseRef), fetchedAt: Date()
    )
  }

  private static let updateSettle: TimeInterval = 15

  /// GitHub's "Update branch", refused if the branch moved since the page loaded. GitHub moves the
  /// branch a moment after accepting the update; returns once it has (true) or after 15 seconds (false).
  func updateBranch(_ key: PrKey, expectedHeadOid: String, config: PrConfig) async throws -> Bool {
    guard let raw = try await GitHub.prDetail(key, token: config.githubToken) else { throw IntegrationError("\(key.repo)#\(key.number) wasn't found") }
    guard raw.headRefOid == expectedHeadOid else {
      throw IntegrationError("The branch has new commits since this page loaded; refresh and try again")
    }
    try await GitHub.updatePullRequestBranch(id: raw.base.id, expectedHeadOid: expectedHeadOid, token: config.githubToken)
    let deadline = Date().addingTimeInterval(Self.updateSettle)
    while Date() < deadline {
      try await Task.sleep(for: .seconds(1))
      if let head = try? await GitHub.prHeadOid(key, token: config.githubToken), head != expectedHeadOid { return true }
    }
    return false
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
