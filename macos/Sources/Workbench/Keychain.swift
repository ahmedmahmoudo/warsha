import Foundation
import Security

/// Credentials in your login keychain, one generic password per key.
enum Keychain {
  private static let service = "com.workbench.app"

  static func get(_ key: String) -> String? {
    var result: AnyObject?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: key,
        kSecReturnData: true,
      ] as CFDictionary,
      &result
    )
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// An empty or nil value removes the key.
  static func set(_ key: String, _ value: String?) {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    guard let value, !value.isEmpty else {
      SecItemDelete(query as CFDictionary)
      return
    }
    let data = Data(value.utf8)
    if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
      var item = query
      item[kSecValueData] = data
      item[kSecAttrLabel] = "Workbench: \(key)"
      SecItemAdd(item as CFDictionary, nil)
    }
  }
}
