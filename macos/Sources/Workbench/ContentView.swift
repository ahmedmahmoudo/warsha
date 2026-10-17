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
      // The saved meetings stay in step with Google, for Today's panels and the changes they flag.
      .task {
        while !Task.isCancelled {
          await calendar.sync(settings, store)
          try? await Task.sleep(for: .seconds(60))
        }
      }
      // Your own PRs stay fresh for the Dock badge, whichever page is open.
      .task {
        while !Task.isCancelled {
          await pullRequests.load(.mine, settings: settings, maxAge: .seconds(15))
          try? await Task.sleep(for: PullRequestsModel.refreshInterval)
        }
      }
      .onChange(of: pullRequests.needsYou(store: store), initial: true) { _, count in
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
      }
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
      NavigationStack { NotPortedView(page: navigation.page) }
    }
  }
}

/// Stands in for a page until it's ported from the web version.
struct NotPortedView: View {
  let page: Page

  var body: some View {
    ContentUnavailableView {
      Label(page.title, systemImage: page.symbol)
    } description: {
      Text("Not ported yet. Use the web version until it is.")
    } actions: {
      Link("Open the web version", destination: URL(string: "http://localhost:5180\(page.webPath)")!)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .workbenchPage()
    .navigationTitle(page.title)
  }
}

private extension Page {
  var webPath: String {
    switch self {
    case .today: "/"
    case .pullRequests: "/prs"
    case .activity: "/activity"
    case .calendar: "/calendar"
    }
  }
}
