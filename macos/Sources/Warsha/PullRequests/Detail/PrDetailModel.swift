import Foundation

/// The details models of the PRs opened lately, so going back to one shows it as it was while it
/// refreshes. The least recently opened go first.
@MainActor
final class PrDetailModels {
  private static let kept = 30
  private var models: [PrKey: PrDetailModel] = [:]
  private var order: [PrKey] = []

  /// The model already made for a PR, without making one.
  func existing(_ key: PrKey) -> PrDetailModel? { models[key] }

  func model(for key: PrKey) -> PrDetailModel {
    order.removeAll { $0 == key }
    order.append(key)
    if let model = models[key] { return model }
    let model = PrDetailModel(key: key)
    models[key] = model
    while order.count > Self.kept { models[order.removeFirst()] = nil }
    return model
  }
}

/// One PR's details, kept fresh: the whole page every minute, and the checks on their own,
/// every 15 seconds while any run and every minute otherwise. When a required check or the head
/// commit changes, the whole page reloads so Merge status agrees.
@MainActor
@Observable
final class PrDetailModel {
  static let refreshInterval: Duration = .seconds(60)
  static let checksRunningInterval: Duration = .seconds(15)
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

  /// `maxAge` skips the load when the page was read at least that recently.
  func load(settings: AppSettings, maxAge: Duration? = nil) async {
    if let maxAge, let fetchedAt = detail?.fetchedAt, Date().timeIntervalSince(fetchedAt) < Double(maxAge.components.seconds) { return }
    if maxAge != nil, detail != nil, RateBudget.shared.lowUntil != nil { return }
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
    guard RateBudget.shared.lowUntil == nil else { return }
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
