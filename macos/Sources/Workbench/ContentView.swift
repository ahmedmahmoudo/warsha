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
        await DevHooks.apply(to: navigation, openSettings: openSettings)
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
    case .activity, .calendar:
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

/// For now, what's in Workbench's own data: the first thing ported.
struct TodayView: View {
  @Environment(Store.self) private var store
  @State private var newTodo = ""

  var body: some View {
    List {
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.bad.color)
      }
      Section("Todos") {
        ForEach(store.todos) { todo in
          Toggle(isOn: Binding(get: { todo.doneAt != nil }, set: { store.setTodo(todo.id, done: $0) })) {
            Text(todo.text)
              .strikethrough(todo.doneAt != nil)
              .foregroundStyle(todo.doneAt == nil ? .primary : .secondary)
          }
          .toggleStyle(.checkbox)
          .contextMenu { Button("Delete", role: .destructive) { store.removeTodo(todo.id) } }
        }
        TextField("Add a todo", text: $newTodo)
          .textFieldStyle(.plain)
          .onSubmit {
            store.addTodo(newTodo)
            newTodo = ""
          }
      }
      Section("Focus") {
        if store.pins.isEmpty { Text("Nothing pinned").foregroundStyle(.secondary) }
        ForEach(store.pins, id: \.ref) { pin in
          Label { LinkOrText(title: pin.title, url: pin.url) } icon: { Image(systemName: "pin") }
            .contextMenu { Button("Unpin") { store.unpin(pin.ref) } }
        }
      }
      Section("Parked") {
        if store.parked.isEmpty { Text("Nothing parked").foregroundStyle(.secondary) }
        ForEach(store.parked, id: \.ref) { item in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              LinkOrText(title: item.title, url: item.url)
              if let reason = item.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
          } icon: {
            Image(systemName: "parkingsign")
          }
          .contextMenu { Button("Unpark") { store.unpark(item.ref) } }
        }
      }
    }
    .listStyle(.inset)
    .workbenchPage()
    .navigationTitle("Today")
    .navigationSubtitle("PRs, tickets and meetings arrive as those pages are ported")
  }
}

private struct LinkOrText: View {
  let title: String
  let url: String?

  var body: some View {
    if let url, let destination = URL(string: url) {
      Link(title, destination: destination)
    } else {
      Text(title)
    }
  }
}
