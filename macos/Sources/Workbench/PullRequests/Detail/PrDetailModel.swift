import Foundation

/// One PR's details, kept fresh: the whole page every 30 seconds, and the checks on their own,
/// every 10 seconds while any run and every minute otherwise. When a required check or the head
/// commit changes, the whole page reloads so Merge status agrees.
@MainActor
@Observable
final class PrDetailModel {
  static let refreshInterval: Duration = .seconds(30)
  static let checksRunningInterval: Duration = .seconds(10)
  static let checksIdleInterval: Duration = .seconds(60)

  let key: PrKey
  private(set) var detail: PrDetail?
  private(set) var error: (any Error)?
  private(set) var loading = false
  /// The latest checks poll, when it's newer than the page.
  private(set) var liveChecks: PrChecks?
  private(set) var checksError: (any Error)?
  private(set) var checkingNow = false

  init(key: PrKey) { self.key = key }

  /// Whichever was read from GitHub last: the checks poll, or the page.
  var checks: (items: [CheckItem], fetchedAt: Date) {
    if let liveChecks, let detail, liveChecks.fetchedAt > detail.fetchedAt { return (liveChecks.checks, liveChecks.fetchedAt) }
    return (detail?.checks ?? [], detail?.fetchedAt ?? Date())
  }

  var isFinished: Bool { detail?.state == .merged || detail?.state == .closed }

  func load(settings: AppSettings) async {
    loading = true
    defer { loading = false }
    do {
      detail = try await PrService.shared.detail(key, config: PrConfig(settings))
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = error
    }
  }

  /// Polls the checks; reloads the page when what Merge status depends on changes.
  func pollChecks(settings: AppSettings) async {
    checkingNow = true
    defer { checkingNow = false }
    do {
      let latest = try await PrService.shared.checks(key, config: PrConfig(settings))
      liveChecks = latest
      checksError = nil
      if let detail, Self.signature(latest.headOid, latest.checks) != Self.signature(detail.headOid, detail.checks) {
        await load(settings: settings)
      }
    } catch is CancellationError {
    } catch {
      checksError = error
    }
  }

  var checksInterval: Duration {
    checks.items.contains { $0.state == .pending } ? Self.checksRunningInterval : Self.checksIdleInterval
  }

  /// What Merge status depends on: the head commit and the required checks. Advisory checks
  /// change every few seconds during CI and only update the checks panel.
  private static func signature(_ headOid: String, _ checks: [CheckItem]) -> String {
    headOid + "|" + checks.filter(\.required).map { "\($0.name):\($0.state)" }.sorted().joined(separator: ",")
  }
}
