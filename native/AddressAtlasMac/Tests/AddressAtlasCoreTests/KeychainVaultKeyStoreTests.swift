import CryptoKit
import Foundation
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
}
