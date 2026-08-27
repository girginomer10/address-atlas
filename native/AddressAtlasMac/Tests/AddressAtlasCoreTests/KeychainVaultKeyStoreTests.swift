import CryptoKit
import Foundation
import Security
import XCTest

@testable import AddressAtlasCore

final class KeychainVaultKeyStoreTests: XCTestCase {
  func testRealKeychainStoreRoundTripsAndPreservesFirstInsertWinner() throws {
    let identifier = UUID().uuidString
    let store = KeychainVaultKeyStore(
      service: "com.addressatlas.tests.\(identifier)",
      account: "vault-key-\(identifier)"
    )
    defer { try? store.deleteVaultKey() }
    let first = Data(repeating: 0x11, count: VaultCrypto.vaultKeyByteCount)
    let competing = Data(repeating: 0x22, count: VaultCrypto.vaultKeyByteCount)
    let replacement = Data(repeating: 0x33, count: VaultCrypto.vaultKeyByteCount)

    XCTAssertNil(try store.loadVaultKey())
    XCTAssertEqual(try store.saveVaultKeyIfAbsent(first), first)
    XCTAssertEqual(try store.saveVaultKeyIfAbsent(competing), first)
    XCTAssertEqual(try store.loadVaultKey(), first)

    try store.saveVaultKey(replacement)
    XCTAssertEqual(try store.loadVaultKey(), replacement)
    try store.deleteVaultKey()
    XCTAssertNil(try store.loadVaultKey())
  }

  func testLegacyFileKeychainItemMigratesIntoDataProtectionKeychain() throws {
    let identifier = UUID().uuidString
    let service = "com.addressatlas.tests.legacy.\(identifier)"
    let account = "vault-key-\(identifier)"
    let store = KeychainVaultKeyStore(
      service: service,
      account: account,
      usesDataProtectionKeychain: true
    )
    defer { try? store.deleteVaultKey() }
    let legacy = Data(repeating: 0x4A, count: VaultCrypto.vaultKeyByteCount)
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    var legacyItem = legacyQuery
    legacyItem[kSecValueData as String] = legacy
    XCTAssertEqual(SecItemAdd(legacyItem as CFDictionary, nil), errSecSuccess)

    let migrated: Data?
    do {
      migrated = try store.loadVaultKey()
    } catch KeychainVaultKeyStoreError.unexpectedStatus(errSecMissingEntitlement) {
      throw XCTSkip(
        "Data Protection Keychain migration requires the signed App ID entitlement; SwiftPM test runners are intentionally unsigned."
      )
    }
    XCTAssertEqual(migrated, legacy)

    XCTAssertEqual(SecItemCopyMatching(legacyQuery as CFDictionary, nil), errSecItemNotFound)
    var protectedQuery = legacyQuery
    protectedQuery[kSecUseDataProtectionKeychain as String] = true
    XCTAssertEqual(SecItemCopyMatching(protectedQuery as CFDictionary, nil), errSecSuccess)
  }
}
