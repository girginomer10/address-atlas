import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class VaultSyncMigrationAndExportTests: XCTestCase {
  func testSchemaV1DocumentDecodesMissingSyncFieldsWithSafeDefaults() throws {
    let json = #"""
      {
        "schemaVersion": 1,
        "preferences": {
          "darkMode": false,
          "density": "comfy",
          "mono": false,
          "hideDust": false,
          "dustThreshold": 5,
          "autoRefresh": true,
          "currency": "USD"
        },
        "wallets": [],
        "customTokens": [],
        "manualHoldings": [],
        "exchangeConnections": [],
        "scanRuns": [],
        "syncState": {
          "accountId": "legacy-user",
          "latestRemoteVersion": 3,
          "lastChecksum": "abc"
        },
        "updatedAt": "2026-07-01T12:00:00Z"
      }
      """#

    let document = try JSONDecoder.addressAtlas.decode(VaultDocument.self, from: Data(json.utf8))

    XCTAssertEqual(document.schemaVersion, VaultDocument.currentSchemaVersion)
    XCTAssertNil(document.syncState.accountId)
    XCTAssertEqual(document.syncState.serverURL, "")
    XCTAssertEqual(document.syncState.sessionToken, "")
    XCTAssertEqual(document.syncState.latestRemoteVersion, 0)
    XCTAssertNil(document.syncState.lastChecksum)
    XCTAssertNil(document.syncState.lastSyncedContentChecksum)
  }

  func testJSONExportOmitsSyncAndCredentialSecrets() throws {
    let credentialCiphertext = "credential-ciphertext-marker"
    let envelope = EncryptedVaultEnvelope(
      keyId: "exchange-id",
      nonce: Base64URL.encode(Data(repeating: 1, count: 12)),
      ciphertext: credentialCiphertext,
      checksum: String(repeating: "a", count: 64)
    )
    var connection = ExchangeConnectionRecord(
      provider: .binance,
      label: "Binance",
      encryptedCredentials: envelope,
      credentialScopeAssurance: .verifiedReadOnly
    )
    connection.lastError = "raw-provider-error-marker"
    let document = VaultDocument(
      exchangeConnections: [connection],
      syncState: SyncState(
        accountId: "private-account-id",
        serverURL: "https://private-sync.example",
        sessionToken: "live-bearer-token",
        lastChecksum: "private-sync-checksum"
      )
    )

    let json = try XCTUnwrap(
      String(data: AddressAtlasExporter.json(for: document), encoding: .utf8))

    XCTAssertFalse(json.contains("syncState"))
    XCTAssertFalse(json.contains("sessionToken"))
    XCTAssertFalse(json.contains("live-bearer-token"))
    XCTAssertFalse(json.contains("encryptedCredentials"))
    XCTAssertFalse(json.contains(credentialCiphertext))
    XCTAssertFalse(json.contains("lastError"))
    XCTAssertFalse(json.contains("raw-provider-error-marker"))
    XCTAssertTrue(json.contains("Binance"))
    XCTAssertTrue(json.contains("verifiedReadOnly"))
  }
}
