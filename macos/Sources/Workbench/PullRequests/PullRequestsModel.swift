import Foundation

/// What the Pull Requests page has loaded, per scope. Switching scope shows the last answer at
/// once while a new one loads, like the web version's query cache.
@MainActor
@Observable
final class PullRequestsModel {
  /// How often an open page reloads; loads are cheap after the first (CODEOWNERS and teams are kept).
  static let refreshInterval: Duration = .seconds(30)

  private(set) var responses: [PrScope: PrsResponse] = [:]
  private(set) var errors: [PrScope: any Error] = [:]
  private(set) var loading: Set<PrScope> = []

  func load(_ scope: PrScope, settings: AppSettings) async {
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
}

extension Store {
  /// What's parked right now: an item whose "until" date has passed is back in play. A PR counts as
  /// parked when it is, or when one of its tickets is.
  func parked(for pr: Pr) -> Parked? {
    let today = Date().formatted(.iso8601.year().month().day())
    let active = parked.filter { $0.until == nil || $0.until! >= today }
    return active.first { $0.ref == prRef(pr.repo, pr.number) }
      ?? pr.tickets.lazy.compactMap { ticket in active.first { $0.ref == ticketRef(ticket.key) } }.first
  }
}
