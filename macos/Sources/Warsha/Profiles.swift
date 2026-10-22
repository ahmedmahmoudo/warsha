import Foundation

/// A separate Warsha: its own GitHub, Linear and Google accounts, settings, pins, notes and
/// open tabs. The window shows one at a time; the toolbar and menu bar switch between them.
struct Profile: Codable, Identifiable, Hashable, Sendable {
  let id: String
  var name: String
}

/// The profiles and which one is in use, kept in UserDefaults outside any profile. The first,
/// "default", is everything from before profiles existed: its keys, secrets and database keep
/// their old names, so nothing moves. Every other profile's are prefixed with its id.
@MainActor
enum Profiles {
  static let defaultID = "default"
  private static let listKey = "profiles"
  private static let currentKey = "currentProfile"
  private static var defaults: UserDefaults { .standard }

  static var all: [Profile] {
    get {
      let saved = defaults.data(forKey: listKey).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
      return saved.contains { $0.id == defaultID } ? saved : [Profile(id: defaultID, name: "Default")] + saved
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: listKey) }
  }

  /// The profile in use. Launch checks (`-WarshaEnvFile`) and tests always use the default.
  static var currentID: String {
    get {
      guard !Keychain.memoryOnly, let id = defaults.string(forKey: currentKey), all.contains(where: { $0.id == id }) else { return defaultID }
      return id
    }
    set { defaults.set(newValue, forKey: currentKey) }
  }

  static var current: Profile { all.first { $0.id == currentID } ?? all[0] }

  /// A key for something that belongs to the profile in use: as it is for the default profile.
  static func scoped(_ key: String, _ id: String = currentID) -> String {
    id == defaultID ? key : "profile.\(id).\(key)"
  }

  /// The profile's database file.
  static func databasePath(_ id: String = currentID) -> URL {
    id == defaultID ? Store.defaultPath : Store.defaultPath.deletingLastPathComponent().appendingPathComponent("warsha-\(id).sqlite")
  }

  private static let onboardedKey = "onboarded"
  /// Launch checks keep it in memory, so a check never marks your real profile done.
  private static var onboardedInMemory = false

  /// Whether the profile has been through Get started. Someone who set Warsha up before it
  /// existed (GitHub already connected) counts as done.
  static func isOnboarded(hasGitHub: Bool) -> Bool {
    if Keychain.memoryOnly { return onboardedInMemory || hasGitHub }
    if let done = ProfileDefaults().object(forKey: onboardedKey) as? Bool { return done }
    if hasGitHub { markOnboarded() }
    return hasGitHub
  }

  static func markOnboarded() {
    if Keychain.memoryOnly { onboardedInMemory = true } else { ProfileDefaults().set(true, forKey: onboardedKey) }
  }

  static func create(named name: String) -> Profile {
    let profile = Profile(id: UUID().uuidString.prefix(8).lowercased(), name: name)
    all.append(profile)
    return profile
  }

  static func rename(_ id: String, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    all = all.map { $0.id == id ? Profile(id: $0.id, name: trimmed) : $0 }
  }

  /// Removes a profile with its settings, secrets and database. The default one stays.
  static func delete(_ id: String) {
    guard id != defaultID else { return }
    all = all.filter { $0.id != id }
    let prefix = "profile.\(id)."
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
    Keychain.removeAll(prefixed: prefix)
    let path = databasePath(id).path
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
  }
}

/// UserDefaults for the profile in use: the same calls, with the key scoped to the profile.
@MainActor
struct ProfileDefaults {
  private let base = UserDefaults.standard
  private let id: String

  init(_ id: String = Profiles.currentID) { self.id = id }

  func set(_ value: Any?, forKey key: String) { base.set(value, forKey: Profiles.scoped(key, id)) }
  func string(forKey key: String) -> String? { base.string(forKey: Profiles.scoped(key, id)) }
  func object(forKey key: String) -> Any? { base.object(forKey: Profiles.scoped(key, id)) }
  func stringArray(forKey key: String) -> [String]? { base.stringArray(forKey: Profiles.scoped(key, id)) }
}
