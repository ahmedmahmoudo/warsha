import Foundation

/// What the Pull Requests page has loaded, per scope. Switching scope shows the last answer at
/// once while a new one loads, like the web version's query cache. Shared by the window, so the
/// sidebar badge and the page read the same answer.
@MainActor
@Observable
final class PullRequestsModel {
  /// How often an open page reloads; loads are cheap after the first (CODEOWNERS and teams are kept).
  static let refreshInterval: Duration = .seconds(60)

  private(set) var responses: [PrScope: PrsResponse] = [:]
  private(set) var errors: [PrScope: any Error] = [:]
  private(set) var loading: Set<PrScope> = []

  /// `maxAge` skips the load when the last answer is at least that recent.
  func load(_ scope: PrScope, settings: AppSettings, maxAge: Duration? = nil) async {
    // A timed refresh waits while GitHub's points are low; Refresh (no maxAge) always runs.
    if maxAge != nil, RateBudget.shared.lowUntil != nil, responses[scope] != nil { return }
    if let maxAge, let fetchedAt = responses[scope]?.fetchedAt,
       Date().timeIntervalSince(fetchedAt) < Double(maxAge.components.seconds) {
      return
    }
    loading.insert(scope)
    defer { loading.remove(scope) }
    do {
      let response = try await PrService.shared.load(scope, config: PrConfig(settings))
      responses[scope] = response
      errors[scope] = nil
      // PRs turning up for the first time are the baseline for "updated since you looked". The
      // team's PRs aren't tracked: they'd all be news.
      if scope != .team {
        AppState.shared.store.markSeen(
          Dictionary((response.open + response.recentlyMerged).map { (prRef($0.repo, $0.number), Seen($0, viewer: response.viewer)) },
                     uniquingKeysWith: { first, _ in first }),
          onlyNew: true
        )
      }
    } catch is CancellationError {
    } catch {
      errors[scope] = error
    }
  }

  /// The teams Team can follow: those in the orgs that own your repos. Nil until read; empty means
  /// Team is off.
  private(set) var teamOptions: [OrgTeam]?
  private(set) var teamOptionsError: String?
  private var teamOptionsKey: String?

  /// Team is there to pick only when your repos' orgs have teams.
  var teamAvailable: Bool { !(teamOptions ?? []).isEmpty }

  /// Reads the teams once per sign-in and choice of repos.
  func loadTeamOptions(settings: AppSettings) async {
    let repos = AppSettings.list(settings.githubRepos)
    let key = "\(settings.githubCredential)|\(repos.joined(separator: ","))"
    guard key != teamOptionsKey else { return }
    teamOptionsKey = key
    guard settings.hasGitHub, !repos.isEmpty else {
      teamOptions = []
      teamOptionsError = nil
      return
    }
    teamOptions = nil
    do {
      teamOptions = try await GitHub.teams(ofOwners: repoOrgs(repos), token: settings.githubCredential)
      teamOptionsError = nil
    } catch {
      teamOptionsKey = nil
      teamOptionsError = error.localizedDescription
      teamOptions = []
    }
  }

  /// Your open PRs waiting on you and not parked, for the sidebar badge.
  func needsYou(store: Store) -> Int {
    responses[.mine]?.open.filter { $0.waitingOn == .you && store.parked(for: $0) == nil }.count ?? 0
  }
}

extension Store {
  /// What's parked right now: an item whose "until" date has passed is back in play. A PR counts as
  /// parked when it is, or when one of its tickets is.
  func parked(for pr: Pr) -> Parked? {
    guard !parkedByRef.isEmpty else { return nil }
    return activeParked(prRef(pr.repo, pr.number)) ?? pr.tickets.lazy.compactMap { self.activeParked(ticketRef($0.key)) }.first
  }
}
