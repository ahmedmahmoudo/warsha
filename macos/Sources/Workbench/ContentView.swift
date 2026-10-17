import SwiftUI

/// The main window: a sidebar of pages and the selected one.
struct ContentView: View {
  @Environment(Navigation.self) private var navigation

  var body: some View {
    @Bindable var navigation = navigation
    NavigationSplitView {
      List(Page.allCases, selection: Binding($navigation.page)) { page in
        Label(page.title, systemImage: page.symbol)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    } detail: {
      switch navigation.page {
      case .today: TodayView()
      case .pullRequests: PullRequestsView()
      case .activity, .calendar: NotPortedView(page: navigation.page)
      }
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
      Section("Todos") {
        ForEach(store.todos) { todo in
          Toggle(isOn: Binding(get: { todo.doneAt != nil }, set: { store.setTodo(todo.id, done: $0) })) {
            Text(todo.text).strikethrough(todo.doneAt != nil)
          }
          .contextMenu { Button("Delete", role: .destructive) { store.removeTodo(todo.id) } }
        }
        TextField("Add a todo", text: $newTodo)
          .onSubmit {
            store.addTodo(newTodo)
            newTodo = ""
          }
      }
      Section("Focus") {
        if store.pins.isEmpty { Text("Nothing pinned").foregroundStyle(.secondary) }
        ForEach(store.pins, id: \.ref) { pin in
          LinkOrText(title: pin.title, url: pin.url)
        }
      }
      Section("Parked") {
        if store.parked.isEmpty { Text("Nothing parked").foregroundStyle(.secondary) }
        ForEach(store.parked, id: \.ref) { item in
          VStack(alignment: .leading) {
            LinkOrText(title: item.title, url: item.url)
            if let reason = item.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      if let error = store.error {
        Text(error).foregroundStyle(.red)
      }
    }
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
