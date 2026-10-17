import AppKit
import SwiftUI

/// Workbench as a native macOS app: one main window with a sidebar of pages, a Settings window and
/// a menu bar item. Everything runs in this process; there's no server.
@main
struct WorkbenchApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  private let state = AppState.shared

  var body: some Scene {
    Window("Workbench", id: "main") {
      ContentView()
        .environment(state.settings)
        .environment(state.store)
        .environment(state.navigation)
        .environment(state.pullRequests)
        .environment(state.calendar)
        .tint(.workbenchAccent)
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 1280, height: 860)
    .commands { PageCommands(navigation: state.navigation) }

    Settings {
      SettingsView()
        .environment(state.settings)
        .environment(state.store)
        .environment(state.calendar)
        .tint(.workbenchAccent)
    }

    MenuBarExtra {
      MenuBarMenu()
        .environment(state.pullRequests)
        .environment(state.store)
    } label: {
      MenuBarLabel()
    }
  }
}

/// Closing the window keeps Workbench in the menu bar; the Dock icon brings the window back.
/// Background work, notifications and the global shortcut start here, apart from any window.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      let state = AppState.shared
      state.notifier.activate()
      GlobalShortcut.apply()
      state.startBackground()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Workbench's pages, in sidebar order.
enum Page: String, CaseIterable, Identifiable {
  case today, pullRequests, activity, calendar

  var id: Self { self }

  var title: String {
    switch self {
    case .today: "Today"
    case .pullRequests: "Pull Requests"
    case .activity: "Activity"
    case .calendar: "Calendar"
    }
  }

  var symbol: String {
    switch self {
    case .today: "sun.max"
    case .pullRequests: "arrow.triangle.pull"
    case .activity: "chart.bar.xaxis"
    case .calendar: "calendar"
    }
  }

  /// ⌘1…⌘4 in the Go menu.
  var shortcut: KeyEquivalent { KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1))) }
}

/// Which page the window shows; the menu bar item and the Go menu change it too.
@MainActor
@Observable
final class Navigation {
  var page: Page = .today
  /// The PR details pages opened from the Pull Requests list, as a back stack.
  var pullRequestPath: [PrKey] = []
}

private struct PageCommands: Commands {
  let navigation: Navigation

  var body: some Commands {
    CommandMenu("Go") {
      ForEach(Page.allCases) { page in
        Button(page.title) { navigation.page = page }
          .keyboardShortcut(page.shortcut)
      }
    }
  }
}

/// The menu bar icon, with how many of your PRs need you. Being always there, it's also where the
/// app learns how to open its window.
private struct MenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let count = AppState.shared.needsYou.count
    HStack(spacing: 3) {
      Image(systemName: "wrench.and.screwdriver")
      if count > 0 { Text("\(count)").monospacedDigit() }
    }
    .onAppear { AppState.shared.openMainWindow = { openWindow(id: "main") } }
  }
}

private struct MenuBarMenu: View {
  private var state: AppState { .shared }

  var body: some View {
    let needsYou = state.needsYou
    Button("Open Workbench") { state.show() }
    if !needsYou.isEmpty {
      Divider()
      Section("Needs you") {
        ForEach(needsYou.prefix(8)) { pr in
          Button("\(pr.status.label) · \(pr.title)") { state.show(pr: PrKey(pr)) }
        }
        if needsYou.count > 8 {
          Button("All \(needsYou.count) in Pull Requests…") { state.show(page: .pullRequests) }
        }
      }
    }
    Divider()
    ForEach(Page.allCases) { page in
      Button(page.title) { state.show(page: page) }
    }
    Divider()
    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
    Divider()
    Button("Quit Workbench") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }
}
