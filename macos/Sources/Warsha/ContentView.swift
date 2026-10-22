import AppKit
import SwiftUI

/// The main window: a sidebar of pages and open PRs, as in Claude, and whichever is selected.
struct ContentView: View {
  @Environment(Navigation.self) private var navigation
  @Environment(PullRequestsModel.self) private var pullRequests
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @Environment(CalendarModel.self) private var calendar
  @AppStorage("showSidebar") private var showSidebar = true

  var body: some View {
    if AppState.shared.onboarding {
      // The tour has the whole window, without the pages' toolbar.
      GetStartedView { AppState.shared.finishOnboarding() }
        .containerBackground(Palette.background, for: .window)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task {
          settings.applyAppearance()
          await DevHooks.apply(to: navigation, openSettings: openSettings)
        }
        .onAppear { AppState.shared.openMainWindow = { openWindow(id: "main") } }
    } else {
      app
    }
  }

  private var app: some View {
    NavigationSplitView(columnVisibility: Binding(
      get: { showSidebar ? .all : .detailOnly },
      set: { showSidebar = $0 != .detailOnly }
    )) {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 200, ideal: Sidebar.width, max: 320)
        .background(Palette.sidebar.ignoresSafeArea())
    } detail: {
      page
    }
    .containerBackground(Palette.background, for: .window)
    .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
    .task {
      settings.applyAppearance()
      DevHooks.borrowGoogleSignIn()
      await DevHooks.apply(to: navigation, openSettings: openSettings)
    }
    .onAppear { AppState.shared.openMainWindow = { openWindow(id: "main") } }
  }

  /// The PR tab in front, or the page. Pages and PRs keep what they've loaded in their models, so
  /// switching back shows them at once.
  @ViewBuilder
  private var page: some View {
    if let tab = navigation.openTab {
      NavigationStack { PrDetailView(key: tab) }.id(tab)
    } else {
      switch navigation.page {
      case .today: NavigationStack { TodayView() }
      case .pullRequests: NavigationStack { PullRequestsView() }
      case .calendar: NavigationStack { CalendarView() }
      case .activity: NavigationStack { ActivityView() }
      case .worktrees: NavigationStack { WorktreesView() }
      }
    }
  }
}
