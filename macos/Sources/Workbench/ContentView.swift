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
      .task {
        settings.applyAppearance()
        DevHooks.borrowGoogleSignIn()
        await DevHooks.apply(to: navigation, openSettings: openSettings)
      }

      .onAppear { AppState.shared.openMainWindow = { openWindow(id: "main") } }
  }

  /// Each page has its own navigation stack, so the PR list keeps its back stack while you look
  /// at another page.
  @ViewBuilder
  private var page: some View {
    @Bindable var navigation = navigation
    switch navigation.page {
    case .today:
      NavigationStack { TodayView() }
    case .pullRequests:
      NavigationStack(path: $navigation.pullRequestPath) {
        PullRequestsView()
          .navigationDestination(for: PrKey.self) { PrDetailView(key: $0) }
      }
    case .calendar:
      NavigationStack { CalendarView() }
    case .activity:
      NavigationStack { ActivityView() }
    }
  }
}
