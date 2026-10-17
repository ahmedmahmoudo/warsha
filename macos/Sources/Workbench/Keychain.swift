import Foundation
import Security

/// Every Workbench secret in one login-keychain item, as a JSON object of key to value, so macOS
/// asks for access once rather than once per secret. New keys go in the same item.
@MainActor
enum Keychain {
  /// Tests use their own service, so they never touch your real secrets.
  static var service = "com.workbench.app" {
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

  static func get(_ key: String) -> String? {
    load()
    return values[key]
  }

  /// An empty or nil value removes the key.
  static func set(_ key: String, _ value: String?) {
    load()
    guard readable else { return }
    if let value, !value.isEmpty { values[key] = value } else { values[key] = nil }
    save()
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

  static func query(_ account: String) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
  }

  private static func read(_ account: String) -> ReadResult {
    var search = query(account)
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
      new[kSecAttrLabel] = "Workbench"
      SecItemAdd(new as CFDictionary, nil)
    }
  }
}
