import Foundation

/// Warsha was called Workbench (bundle com.workbench.app). On the first launch after the rename,
/// its settings and database come across, so nothing is lost; its Keychain item moves over on the
/// first read (see Keychain). Runs before anything reads UserDefaults or opens the database.
@MainActor
enum FromWorkbench {
  static let bundleID = "com.workbench.app"

  static func migrate() {
    guard !DevHooks.isHostingTests else { return }
    moveSettings()
    moveData()
  }

  /// Workbench's UserDefaults under Warsha's bundle, keeping anything Warsha already has.
  private static func moveSettings() {
    let defaults = UserDefaults.standard
    guard let id = Bundle.main.bundleIdentifier, id != bundleID,
          let old = defaults.persistentDomain(forName: bundleID), !old.isEmpty
    else { return }
    let current = defaults.persistentDomain(forName: id) ?? [:]
    defaults.setPersistentDomain(current.merging(old) { mine, _ in mine }, forName: id)
    defaults.removePersistentDomain(forName: bundleID)
  }

  /// ~/Library/Application Support/Workbench becomes …/Warsha, with workbench.sqlite (and each
  /// profile's workbench-<id>.sqlite, and their -wal and -shm files) renamed to match.
  private static func moveData() {
    let manager = FileManager.default
    let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let old = support.appendingPathComponent("Workbench")
    let new = Store.defaultPath.deletingLastPathComponent()
    guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else { return }
    do {
      try manager.moveItem(at: old, to: new)
      for name in try manager.contentsOfDirectory(atPath: new.path) where name.hasPrefix("workbench") {
        let renamed = "warsha" + name.dropFirst("workbench".count)
        try manager.moveItem(at: new.appendingPathComponent(name), to: new.appendingPathComponent(renamed))
      }
    } catch {
      log.error("Couldn't move Workbench's data to \(new.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }
}
