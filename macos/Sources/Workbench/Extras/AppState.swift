import AppKit
import SwiftUI

/// The app's long-lived models, shared by the window, the Settings window, the menu bar item and
/// the background work, which keeps going while the window is closed.
@MainActor
@Observable
final class AppState {
  static let shared = AppState()

  // The profile's models, replaced together when you switch profile; views read them through
  // here, so the window rebuilds with the new ones.
  private(set) var settings = AppSettings()
  private(set) var store = Store.open(at: Profiles.databasePath())
  private(set) var navigation = Navigation()
  private(set) var pullRequests = PullRequestsModel()
  private(set) var calendar = CalendarModel()
  /// What each page has loaded, kept while you look at another page so coming back shows it at once.
  private(set) var today = TodayModel()
  private(set) var activity = ActivityModel()
  @ObservationIgnored private(set) var prDetails = PrDetailModels()
  private(set) var worktrees = WorktreesModel()
  private(set) var profile = Profiles.current
  @ObservationIgnored let notifier = Notifier()
  @ObservationIgnored let signIns = SignIns()

  /// Switches every model to another profile and starts its background refresh.
  func switchProfile(to id: String) {
    guard id != profile.id else { return }
    Profiles.currentID = id
    for task in background { task.cancel() }
    background = []
    settings = AppSettings()
    store = Store.open(at: Profiles.databasePath())
    navigation = Navigation()
    pullRequests = PullRequestsModel()
    calendar = CalendarModel()
    today = TodayModel()
    activity = ActivityModel()
    prDetails = PrDetailModels()
    worktrees = WorktreesModel()
    profile = Profiles.current
    notifier.reloadProfile()
    NSApp.dockTile.badgeLabel = nil
    settings.applyAppearance()
    startBackground()
  }

  /// Every profile, for the switchers.
  private(set) var profiles = Profiles.all

  /// Makes a profile and switches to it; Get started then asks for its accounts.
  func createProfile(named name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let created = Profiles.create(named: trimmed.isEmpty ? "Profile \(profiles.count + 1)" : trimmed)
    profiles = Profiles.all
    switchProfile(to: created.id)
  }

  func renameProfile(_ id: String, to name: String) {
    Profiles.rename(id, to: name)
    profiles = Profiles.all
    profile = Profiles.current
  }

  /// Deletes a profile and everything in it; deleting the one in use switches to the default first.
  func deleteProfile(_ id: String) {
    guard id != Profiles.defaultID else { return }
    if profile.id == id { switchProfile(to: Profiles.defaultID) }
    Profiles.delete(id)
    profiles = Profiles.all
  }

  /// Opens (or brings back) the main window; set by a view that can, since only views get
  /// SwiftUI's openWindow.
  @ObservationIgnored var openMainWindow: () -> Void = {}

  @ObservationIgnored private var background: [Task<Void, Never>] = []
  @ObservationIgnored private var observingWake = false

  /// Brings Workbench forward with the window showing, optionally on a page or a PR.
  func show(page: Page? = nil, pr: PrKey? = nil) {
    if let pr {
      navigation.open(pr)
    } else if let page {
      navigation.show(page)
    }
    openMainWindow()
    NSApp.activate()
  }

  /// Your PRs, review requests and calendar stay fresh whichever page is open, or none: for the
  /// Dock and menu bar counts and for notifications.
  func startBackground() {
    guard background.isEmpty else { return }
    // A sign-in can expire while the Mac sleeps: renew it on waking, before anything loads.
    if !observingWake {
      observingWake = true
      NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { Task { await AppState.shared.signIns.refreshIfNeeded(AppState.shared.settings) } }
      }
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
      // Local worktrees, for the chip beside each PR that has one.
      loop(every: .seconds(300)) { state in
        await state.worktrees.scan(settings: state.settings)
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
