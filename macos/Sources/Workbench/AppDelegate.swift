import AppKit

/// Workbench's pages, for the menu bar item and the Go menu.
private let pages: [(title: String, path: String, key: String)] = [
  ("Today", "/", "1"),
  ("Pull Requests", "/prs", "2"),
  ("Activity", "/activity", "3"),
  ("Calendar", "/calendar", "4"),
  ("Settings", "/settings", ","),
]

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let server = ServerProcess()
  private var window: MainWindow!
  private var statusItem: NSStatusItem!
  private let serverStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.mainMenu = mainMenu()
    window = MainWindow()
    setUpStatusItem()

    server.onStateChange = { [weak self] state in
      self?.window.serverChanged(state)
      self?.updateServerStatus(state)
    }
    updateServerStatus(server.state)
    server.start()

    window.showWindow(nil)
    NSApp.activate()
  }

  /// Closing the window keeps Workbench in the menu bar; the Dock icon brings the window back.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { window.showWindow(nil) }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    server.stop()
  }

  // MARK: Actions

  @objc func openWindow(_ sender: Any?) {
    window.showWindow(nil)
    NSApp.activate()
  }

  @objc func openPage(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    window.open(path: path)
  }

  @objc func restartServer(_ sender: Any?) {
    server.restart()
  }

  @objc func showServerLog(_ sender: Any?) {
    NSWorkspace.shared.open(Config.logFile)
  }

  @objc func openInBrowser(_ sender: Any?) {
    NSWorkspace.shared.open(Config.baseURL)
  }

  // MARK: Menu bar item

  private func setUpStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Workbench")

    let menu = NSMenu()
    menu.addItem(withTitle: "Open Workbench", action: #selector(openWindow(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    for page in pages { menu.addItem(pageItem(page.title, page.path, key: "")) }
    menu.addItem(.separator())
    serverStatus.isEnabled = false
    menu.addItem(serverStatus)
    menu.addItem(withTitle: "Restart Server", action: #selector(restartServer(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Show Server Log", action: #selector(showServerLog(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
  }

  private func updateServerStatus(_ state: ServerProcess.State) {
    serverStatus.title = switch state {
    case .starting: "Server starting…"
    case .running: "Server running on port \(Config.port)"
    case .failed: "Server stopped"
    }
  }

  private func pageItem(_ title: String, _ path: String, key: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(openPage(_:)), keyEquivalent: key)
    item.representedObject = path
    return item
  }

  // MARK: Main menu

  /// The standard menus. Edit matters most: without it, copy and paste don't work in the pages.
  private func mainMenu() -> NSMenu {
    let main = NSMenu()

    let app = NSMenu()
    app.addItem(withTitle: "About Workbench", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(pageItem("Settings…", "/settings", key: ","))
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Workbench", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(submenu: app, title: "Workbench")

    let file = NSMenu(title: "File")
    file.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "o")
    file.addItem(.separator())
    file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    main.addItem(submenu: file, title: "File")

    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    main.addItem(submenu: edit, title: "Edit")

    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Reload", action: #selector(MainWindow.reloadPage(_:)), keyEquivalent: "r")
    view.addItem(.separator())
    let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    main.addItem(submenu: view, title: "View")

    let go = NSMenu(title: "Go")
    go.addItem(withTitle: "Back", action: #selector(MainWindow.goBack(_:)), keyEquivalent: "[")
    go.addItem(withTitle: "Forward", action: #selector(MainWindow.goForward(_:)), keyEquivalent: "]")
    go.addItem(.separator())
    for page in pages where page.path != "/settings" { go.addItem(pageItem(page.title, page.path, key: page.key)) }
    main.addItem(submenu: go, title: "Go")

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Workbench", action: #selector(openWindow(_:)), keyEquivalent: "0")
    main.addItem(submenu: windowMenu, title: "Window")
    NSApp.windowsMenu = windowMenu

    return main
  }
}

private extension NSMenu {
  func addItem(submenu: NSMenu, title: String) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    addItem(item)
  }
}
