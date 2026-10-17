import Foundation
import Security
import Testing
@testable import Workbench

@MainActor
struct KeychainTests {
  @Test func movesOldItemsIntoOneAndKeepsNewKeysThere() {
    Keychain.service = "com.workbench.tests.\(UUID().uuidString)"
    defer {
      SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: Keychain.service] as CFDictionary)
      Keychain.service = "com.workbench.app"
    }
    // An item from before, one per secret.
    var legacy = Keychain.query("githubToken")
    legacy[kSecValueData] = Data("ghp_old".utf8)
    #expect(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess)

    #expect(Keychain.get("githubToken") == "ghp_old")
    #expect(SecItemCopyMatching(Keychain.query("githubToken") as CFDictionary, nil) == errSecItemNotFound)

    Keychain.set("googleRefreshToken", "new")
    Keychain.set("githubToken", "")
    // Read back from the Keychain, not the in-memory copy.
    Keychain.service = Keychain.service
    #expect(Keychain.get("googleRefreshToken") == "new")
    #expect(Keychain.get("githubToken") == nil)
  }
}
