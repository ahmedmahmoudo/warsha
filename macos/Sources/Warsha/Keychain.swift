import Foundation
import Security

/// Every Warsha secret in one login-keychain item, as a JSON object of key to value, so macOS
/// asks for access once rather than once per secret. New keys go in the same item.
@MainActor
enum Keychain {
  /// Tests use their own service, so they never touch your real secrets.
  static let defaultService = "com.warsha.app"
  static var service = defaultService {
    didSet { loaded = false; values = [:] }
  }
  private static let account = "secrets"
  /// Items from before everything lived in one, moved over (and removed) on first read.
  private static let legacyAccounts = ["githubToken", "linearApiKey", "googleClientSecret"]

  private static var values: [String: String] = [:]
  private static var loaded = false
  /// Reading was refused (access denied or cancelled): writing now would replace secrets that are
  /// still there, so writes wait until a read works.
  private static var readable = false

  /// In memory only, never the login keychain: while the app runs from a settings file or hosts
  /// tests (see DevHooks), so nothing prompts and nothing real is touched.
  static var memoryOnly: Bool { DevHooks.envFile != nil || DevHooks.isHostingTests }

  /// Keys belong to the profile in use: the default profile's are as they always were, others'
  /// are prefixed, all in the same item.
  static func get(_ key: String) -> String? {
    let key = Profiles.scoped(key)
    if memoryOnly { return values[key] }
    load()
    return values[key]
  }

  /// An empty or nil value removes the key.
  static func set(_ key: String, _ value: String?) {
    let key = Profiles.scoped(key)
    if memoryOnly {
      values[key] = value?.isEmpty == false ? value : nil
      return
    }
    load()
    guard readable else { return }
    if let value, !value.isEmpty { values[key] = value } else { values[key] = nil }
    save()
  }

  /// Forgets every secret whose key starts with `prefix`: a deleted profile's.
  static func removeAll(prefixed prefix: String) {
    if !memoryOnly { load() }
    guard memoryOnly || readable else { return }
    values = values.filter { !$0.key.hasPrefix(prefix) }
    if !memoryOnly { save() }
  }

  private static func load() {
    guard !loaded else { return }
    loaded = true
    switch read(account) {
    case let .found(data):
      values = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
      readable = true
    case .missing:
      readable = true
      migrate()
    case .refused:
      readable = false
    }
  }

  private static func migrate() {
    // Workbench's item, from before the rename (macOS may ask once, as it's another app's item).
    if service == defaultService, case let .found(data) = read(account, service: FromWorkbench.bundleID) {
      values = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
      save()
      SecItemDelete(query(account, service: FromWorkbench.bundleID) as CFDictionary)
      return
    }
    var moved: [String] = []
    for legacy in legacyAccounts {
      if case let .found(data) = read(legacy) {
        values[legacy] = String(decoding: data, as: UTF8.self)
        moved.append(legacy)
      }
    }
    guard !moved.isEmpty else { return }
    save()
    for legacy in moved { SecItemDelete(query(legacy) as CFDictionary) }
  }

  private enum ReadResult {
    case found(Data)
    case missing
    case refused
  }

  static func query(_ account: String, service: String = Self.service) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
  }

  private static func read(_ account: String, service: String = Self.service) -> ReadResult {
    var search = query(account, service: service)
    search[kSecReturnData] = true
    var result: AnyObject?
    switch SecItemCopyMatching(search as CFDictionary, &result) {
    case errSecSuccess: return (result as? Data).map(ReadResult.found) ?? .missing
    case errSecItemNotFound: return .missing
    default: return .refused
    }
  }

  private static func save() {
    let data = (try? JSONEncoder().encode(values)) ?? Data()
    let item = query(account)
    if SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
      var new = item
      new[kSecValueData] = data
      new[kSecAttrLabel] = "Warsha"
      SecItemAdd(new as CFDictionary, nil)
    }
  }
}
