import Foundation

/// What the Pull Requests page has loaded, per scope. Switching scope shows the last answer at
/// once while a new one loads, like the web version's query cache. Shared by the window, so the
/// sidebar badge and the page read the same answer.
@MainActor
@Observable
final class PullRequestsModel {
  /// How often an open page reloads; loads are cheap after the first (CODEOWNERS and teams are kept).
  static let refreshInterval: Duration = .seconds(30)

  private(set) var responses: [PrScope: PrsResponse] = [:]
  private(set) var errors: [PrScope: any Error] = [:]
  private(set) var loading: Set<PrScope> = []

  /// `maxAge` skips the load when the last answer is at least that recent.
  func load(_ scope: PrScope, settings: AppSettings, maxAge: Duration? = nil) async {
    if let maxAge, let fetchedAt = responses[scope]?.fetchedAt,
       Date().timeIntervalSince(fetchedAt) < Double(maxAge.components.seconds) {
      return
    }
    loading.insert(scope)
    defer { loading.remove(scope) }
    do {
      responses[scope] = try await PrService.shared.load(scope, config: PrConfig(settings))
      errors[scope] = nil
    } catch is CancellationError {
    } catch {
      errors[scope] = error
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
