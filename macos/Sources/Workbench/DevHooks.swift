import AppKit
import SwiftUI

/// Launch arguments for checking the app without clicking through it, used while developing:
///
///   open Workbench.app --args -WorkbenchEnvFile /path/.env.local -WorkbenchOpen owner/repo#123 \
///     -WorkbenchAppearance dark -WorkbenchSnapshot /tmp/shot.png
///
/// `-WorkbenchAppearance` overrides Settings → General → Appearance for this launch.
/// `-WorkbenchEnvFile` reads settings from a file for this launch only, without the Keychain.
/// `-WorkbenchOpen` opens a page ("prs", "today"), a PR's details, or "settings". `-WorkbenchSnapshot` saves the
/// window as a PNG once it has loaded (`-WorkbenchSnapshotDelay`, seconds, default 15). The app draws
/// its own window, so no screen-recording permission is needed.
enum DevHooks {
  private static var defaults: UserDefaults { .standard }

  static var envFile: String? { defaults.string(forKey: "WorkbenchEnvFile") }

  /// The app is hosting Xcode's tests: it leaves the Keychain and your settings alone.
  static var isHostingTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

  @MainActor
  static func apply(to navigation: Navigation, openSettings: OpenSettingsAction) async {
    switch defaults.string(forKey: "WorkbenchAppearance") {
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    default: break
    }
    if let target = defaults.string(forKey: "WorkbenchOpen") {
      if target == "settings" {
        openSettings()
      } else if let page = Page.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(target.lowercased()) }) {
        navigation.page = page
      } else if let match = target.wholeMatch(of: /([\w.-]+\/[\w.-]+)#(\d+)/), let number = Int(match.2) {
        navigation.page = .pullRequests
        navigation.pullRequestPath = [PrKey(repo: String(match.1), number: number)]
      }
    }
    guard let path = defaults.string(forKey: "WorkbenchSnapshot") else { return }
    let delay = defaults.double(forKey: "WorkbenchSnapshotDelay")
    try? await Task.sleep(for: .seconds(delay > 0 ? delay : 15))
    snapshot(to: path)
  }

  @MainActor
  private static func snapshot(to path: String) {
    guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title != "" }),
          let view = window.contentView?.superview ?? window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}
