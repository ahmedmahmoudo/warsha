import AppKit
import SwiftUI

/// The app's long-lived models, shared by the window, the Settings window, the menu bar item and
/// the background work, which keeps going while the window is closed.
@MainActor
final class AppState {
  static let shared = AppState()

  let settings = AppSettings()
  let store = Store.open()
  let navigation = Navigation()
  let pullRequests = PullRequestsModel()
  let calendar = CalendarModel()
  let notifier = Notifier()
  let signIns = SignIns()

  /// Opens (or brings back) the main window; set by a view that can, since only views get
  /// SwiftUI's openWindow.
  var openMainWindow: () -> Void = {}

  private var background: [Task<Void, Never>] = []

  /// Brings Workbench forward with the window showing, optionally on a page or a PR.
  func show(page: Page? = nil, pr: PrKey? = nil) {
    if let pr {
      // On the page you're on, so Back returns there.
      navigation.open(pr)
    } else if let page {
      navigation.page = page
    }
    openMainWindow()
    NSApp.activate()
  }

  /// Your PRs, review requests and calendar stay fresh whichever page is open, or none: for the
  /// Dock and menu bar counts and for notifications.
  func startBackground() {
    guard background.isEmpty else { return }
    // A sign-in can expire while the Mac sleeps: renew it on waking, before anything loads.
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { Task { await AppState.shared.signIns.refreshIfNeeded(AppState.shared.settings) } }
    }
    background = [
      loop(every: .seconds(30)) { state in
        await state.pullRequests.load(.mine, settings: state.settings, maxAge: .seconds(15))
      },
      loop(every: .seconds(120)) { state in
        await state.pullRequests.load(.reviewing, settings: state.settings, maxAge: .seconds(60))
      },
      loop(every: .seconds(60)) { state in
        await state.calendar.sync(state.settings, state.store)
      },
      // Meetings starting soon need checking more often than anything is loaded.
      loop(every: .seconds(20)) { _ in },
    ]
  }

  private func loop(every interval: Duration, _ work: @escaping @MainActor (AppState) async -> Void) -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled, let self {
        await signIns.refreshIfNeeded(settings)
        await work(self)
        updateBadge()
        await notifier.check(self)
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// Your open PRs waiting on you and not parked: the Dock badge and the menu bar count.
  var needsYou: [Pr] {
    pullRequests.responses[.mine]?.open.filter { $0.waitingOn == .you && store.parked(for: $0) == nil } ?? []
  }

  private func updateBadge() {
    let count = needsYou.count
    NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }
}
