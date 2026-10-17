import AppKit
import SwiftUI

/// Workbench as a native macOS app: one main window with a sidebar of pages, a Settings window and
/// a menu bar item. Everything runs in this process; there's no server.
@main
struct WorkbenchApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var settings = AppSettings()
  @State private var store = Store.open()
  @State private var navigation = Navigation()

  var body: some Scene {
    Window("Workbench", id: "main") {
      ContentView()
        .environment(settings)
        .environment(store)
        .environment(navigation)
        .frame(minWidth: 720, minHeight: 480)
    }
    .defaultSize(width: 1280, height: 860)
    .commands { PageCommands(navigation: navigation) }

    Settings {
      SettingsView()
        .environment(settings)
        .environment(store)
    }

    MenuBarExtra("Workbench", systemImage: "wrench.and.screwdriver") {
      MenuBarMenu(navigation: navigation)
    }
  }
}

/// Closing the window keeps Workbench in the menu bar; the Dock icon brings the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
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

private struct MenuBarMenu: View {
  let navigation: Navigation
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Open Workbench") { show(nil) }
    Divider()
    ForEach(Page.allCases) { page in
      Button(page.title) { show(page) }
    }
    Divider()
    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
    Divider()
    Button("Quit Workbench") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func show(_ page: Page?) {
    if let page { navigation.page = page }
    openWindow(id: "main")
    NSApp.activate()
  }
}
