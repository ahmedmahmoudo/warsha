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
    page
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Page", selection: $navigation.page) {
            ForEach(Page.allCases) { page in
              Text(page.title).tag(page)
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

  /// Each page has its own navigation stack: a PR opened from a page goes back to that page, and
  /// each page keeps its back stack while you look at another.
  @ViewBuilder
  private var page: some View {
    switch navigation.page {
    case .today: stack(.today) { TodayView() }
    case .pullRequests: stack(.pullRequests) { PullRequestsView() }
    case .calendar: stack(.calendar) { CalendarView() }
    case .activity: stack(.activity) { ActivityView() }
    }
  }

  private func stack<Root: View>(_ page: Page, @ViewBuilder root: () -> Root) -> some View {
    NavigationStack(path: navigation.path(page)) {
      root().navigationDestination(for: PrKey.self) { PrDetailView(key: $0) }
    }
  }
}
