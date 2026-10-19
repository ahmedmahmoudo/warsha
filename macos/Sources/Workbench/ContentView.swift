import AppKit
import SwiftUI

/// The main window: the pages as tabs in the toolbar, like the web version's top bar, and the
/// selected page below.
struct ContentView: View {
  @Environment(Navigation.self) private var navigation
  @Environment(PullRequestsModel.self) private var pullRequests
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @Environment(CalendarModel.self) private var calendar

  var body: some View {
    @Bindable var navigation = navigation
    VStack(spacing: 0) {
      if !navigation.tabs.isEmpty {
        PrTabStrip()
        Divider().overlay(Palette.border)
      }
      page
    }
    .toolbar {
      if AppState.shared.profiles.count > 1 {
        ToolbarItem(placement: .navigation) { ProfileMenu() }
      }
      ToolbarItem(placement: .principal) {
        // Shows no page while a PR tab is in front; picking one goes back to it.
        Picker("Page", selection: Binding(get: { navigation.selectedPage }, set: { $0.map(navigation.show) })) {
          ForEach(Page.allCases) { page in
            Text(page.title).tag(Optional(page))
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
    }
    .containerBackground(Palette.background, for: .window)
    // The toolbar in the page's colour rather than the system's, with the standard glass
    // controls on it; glass takes its tint from what's behind it.
    .toolbarBackground(Palette.background, for: .windowToolbar)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
    .sheet(isPresented: $navigation.gettingStarted) { GetStartedSheet() }
    .task {
      settings.applyAppearance()
      if !settings.hasGitHub { navigation.gettingStarted = true }
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
