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
        .textScale(state.settings.textScale)
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 1280, height: 860)
    .commands {
      PageCommands(navigation: state.navigation)
      TextSizeCommands(settings: state.settings)
    }

    Settings {
      SettingsView()
        .environment(state.settings)
        .environment(state.store)
        .environment(state.calendar)
        .tint(.workbenchAccent)
        .textScale(state.settings.textScale)
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
      // ⌘= zooms in too, as in browsers, without Shift for the +.
      NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "="
        else { return event }
        state.settings.textScale = TextScale.larger(than: state.settings.textScale)
        return nil
      }
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
  /// Each page's back stack of PR details, so Back returns to the page a PR was opened from.
  var paths: [Page: [PrKey]] = [:]

  /// Opens a PR's details on the page you're on.
  func open(_ pr: PrKey) {
    paths[page, default: []].append(pr)
  }

  func path(_ page: Page) -> Binding<[PrKey]> {
    Binding(get: { self.paths[page] ?? [] }, set: { self.paths[page] = $0 })
  }
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

/// View → Zoom In, Zoom Out and Actual Size, for the text size (also in Settings → General).
private struct TextSizeCommands: Commands {
  let settings: AppSettings

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Section {
        Button("Actual Size") { settings.textScale = 1 }
          .keyboardShortcut("0")
          .disabled(settings.textScale == 1)
        Button("Zoom In") { settings.textScale = TextScale.larger(than: settings.textScale) }
          .keyboardShortcut("+")
          .disabled(settings.textScale >= TextScale.steps.last!)
        Button("Zoom Out") { settings.textScale = TextScale.smaller(than: settings.textScale) }
          .keyboardShortcut("-")
          .disabled(settings.textScale <= TextScale.steps.first!)
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
      // The board icon is a template image in Assets.xcassets; a SwiftPM build without actool has no
      // catalog, so it falls back to a symbol.
      if let icon = NSImage(named: "MenuBarIcon") {
        Image(nsImage: icon)
      } else {
        Image(systemName: "wrench.and.screwdriver")
      }
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
