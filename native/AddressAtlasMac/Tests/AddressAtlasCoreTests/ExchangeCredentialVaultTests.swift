import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class ExchangeCredentialVaultTests: XCTestCase {
  func testExchangeCredentialsUseDedicatedSubkey() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    let credentials = ExchangeCredentials(apiKey: "api", secret: "secret", passphrase: "pass")

    let envelope = try credentialVault.seal(credentials, vaultKey: vaultKey, connectionId: UUID())
    let opened = try credentialVault.open(envelope, vaultKey: vaultKey)

    XCTAssertEqual(opened, credentials)

    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    XCTAssertThrowsError(
      try crypto.openJSON(ExchangeCredentials.self, envelope: envelope, with: localKey))
  }
}
