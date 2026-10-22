import AppKit
import SwiftUI

/// Warsha as a native macOS app: one main window with a sidebar of pages, a Settings window and
/// a menu bar item. Everything runs in this process; there's no server.
@main
struct WarshaApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  private let state: AppState

  init() {
    FromWorkbench.migrate()
    state = AppState.shared
  }

  var body: some Scene {
    Window("Warsha", id: "main") {
      ProfileScoped { ContentView().frame(minWidth: 760, minHeight: 480) }
    }
    .defaultSize(width: 1280, height: 860)
    .commands {
      PageCommands(state: state)
      TextSizeCommands(state: state)
    }

    Settings {
      ProfileScoped { SettingsView() }
    }

    MenuBarExtra {
      ProfileScoped { MenuBarMenu() }
    } label: {
      MenuBarLabel()
    }
  }
}

/// The profile's models as the environment, rebuilt from scratch when you switch profile.
private struct ProfileScoped<Content: View>: View {
  @ViewBuilder let content: Content
  @State private var state = AppState.shared

  var body: some View {
    content
      .environment(state.settings)
      .environment(state.store)
      .environment(state.navigation)
      .environment(state.pullRequests)
      .environment(state.calendar)
      .environment(state.today)
      .environment(state.activity)
      .environment(state.worktrees)
      .environment(state)
      .tint(.warshaAccent)
      .textScale(state.settings.textScale)
      .id(state.profile.id)
  }
}

/// Closing the window keeps Warsha in the menu bar; the Dock icon brings the window back.
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

/// Warsha's pages, in sidebar order.
enum Page: String, CaseIterable, Identifiable {
  case today, pullRequests, activity, calendar, worktrees

  var id: Self { self }

  var title: String {
    switch self {
    case .today: "Today"
    case .pullRequests: "Pull Requests"
    case .activity: "Activity"
    case .calendar: "Calendar"
    case .worktrees: "Worktrees"
    }
  }

  var symbol: String {
    switch self {
    case .today: "sun.max"
    case .pullRequests: "arrow.triangle.pull"
    case .activity: "chart.bar.xaxis"
    case .calendar: "calendar"
    case .worktrees: "arrow.triangle.branch"
    }
  }

  /// ⌘1…⌘5 in the Go menu.
  var shortcut: KeyEquivalent { KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1))) }
}

/// Which page or PR tab the window shows; the menu bar item and the Go menu change it too. Each PR
/// you open gets a tab beside the pages, like a browser's, so opening one never loses your place;
/// the tabs are remembered between launches.
@MainActor
@Observable
final class Navigation {
  private static let tabsKey = "openPrTabs"
  private static let tabsKept = 20

  /// The page shown when no PR tab is.
  private(set) var page: Page = .today
  /// Open PR tabs, in the order they sit in the tab strip.
  private(set) var tabs: [PrKey] = Navigation.savedTabs()
  /// The PR tab showing, or nil for the page.
  private(set) var openTab: PrKey?

  /// What the page picker shows: nothing while a PR tab is in front.
  var selectedPage: Page? { openTab == nil ? page : nil }

  func show(_ page: Page) {
    self.page = page
    openTab = nil
  }

  /// Opens a PR in its own tab, just after the one in front, or brings its tab forward.
  func open(_ pr: PrKey) {
    if !tabs.contains(pr) {
      let after = openTab.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.endIndex
      tabs.insert(pr, at: after)
      if tabs.count > Self.tabsKept, let oldest = tabs.first(where: { $0 != pr }) { tabs.removeAll { $0 == oldest } }
      saveTabs()
    }
    openTab = pr
  }

  /// Closes a tab; closing the one in front shows its neighbour, or the page when it was the last.
  func close(_ pr: PrKey) {
    guard let index = tabs.firstIndex(of: pr) else { return }
    tabs.remove(at: index)
    if openTab == pr { openTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
    saveTabs()
  }

  func closeOthers(_ pr: PrKey) {
    tabs = tabs.filter { $0 == pr }
    if openTab != nil { openTab = pr }
    saveTabs()
  }

  func closeAll() {
    tabs = []
    openTab = nil
    saveTabs()
  }

  /// The next or previous tab, pages first and then PRs, wrapping round.
  func cycle(_ step: Int) {
    let all: [PrKey?] = [nil] + tabs.map(Optional.some)
    guard all.count > 1, let index = all.firstIndex(of: openTab) else { return }
    openTab = all[(index + step + all.count) % all.count]
  }

  func move(_ pr: PrKey, before target: PrKey) {
    guard pr != target, let from = tabs.firstIndex(of: pr) else { return }
    tabs.remove(at: from)
    tabs.insert(pr, at: tabs.firstIndex(of: target) ?? tabs.endIndex)
    saveTabs()
  }

  private func saveTabs() {
    // Launch checks leave your real tabs alone.
    guard !Keychain.memoryOnly else { return }
    ProfileDefaults().set(tabs.map { "\($0.repo)#\($0.number)" }, forKey: Self.tabsKey)
  }

  private static func savedTabs() -> [PrKey] {
    (ProfileDefaults().stringArray(forKey: tabsKey) ?? []).compactMap { saved in
      guard let match = saved.wholeMatch(of: /(.+)#(\d+)/), let number = Int(match.2) else { return nil }
      return PrKey(repo: String(match.1), number: number)
    }
  }
}

private struct PageCommands: Commands {
  let state: AppState
  private var navigation: Navigation { state.navigation }

  var body: some Commands {
    CommandMenu("Go") {
      ForEach(Page.allCases) { page in
        Button(page.title) { navigation.show(page) }
          .keyboardShortcut(page.shortcut)
      }
      Divider()
      Button("Next Tab") { navigation.cycle(1) }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(navigation.tabs.isEmpty)
      Button("Previous Tab") { navigation.cycle(-1) }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(navigation.tabs.isEmpty)
    }
    // ⌘W closes the PR tab in front; with a page in front it closes the window as usual.
    CommandGroup(before: .saveItem) {
      if let tab = navigation.openTab {
        Button("Close Tab") { navigation.close(tab) }
          .keyboardShortcut("w")
      }
    }
    CommandGroup(replacing: .help) {
      Button("Get Started…") { state.startOnboarding() }
    }
  }
}

/// View → Zoom In, Zoom Out and Actual Size, for the text size (also in Settings → General).
private struct TextSizeCommands: Commands {
  let state: AppState
  private var settings: AppSettings { state.settings }

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
    Button("Open Warsha") { state.show() }
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
    Menu("Profile: \(state.profile.name)") {
      ForEach(state.profiles) { profile in
        Toggle(profile.name, isOn: Binding(get: { state.profile.id == profile.id }, set: { if $0 { state.switchProfile(to: profile.id) } }))
      }
      Divider()
      SettingsLink { Text("Manage Profiles…") }
    }
    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
    Divider()
    Button("Quit Warsha") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }
}
