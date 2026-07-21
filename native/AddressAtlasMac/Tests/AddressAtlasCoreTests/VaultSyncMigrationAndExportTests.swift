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
    let credentialCanary = "credential-api-key-marker"
    let vaultKey = try VaultCrypto().generateVaultKey()
    let connectionId = UUID()
    let envelope = try ExchangeCredentialVault().seal(
      ExchangeCredentials(apiKey: credentialCanary, secret: "credential-secret-marker"),
      vaultKey: vaultKey,
      connectionId: connectionId
    )
    var connection = ExchangeConnectionRecord(
      id: connectionId,
      provider: .binance,
      label: "Binance",
      encryptedCredentials: envelope,
      credentialScopeAssurance: .verifiedReadOnly
    )
    connection.status = .failed
    connection.lastTestedAt = Date(timeIntervalSince1970: 1)
    connection.lastError = "raw-provider-error-marker"
    let accountId = "abababab-abab-4bab-8bab-abababababab"
    let sessionToken = testSessionToken(accountId: accountId)
    let document = VaultDocument(
      exchangeConnections: [connection],
      syncState: SyncState(
        accountId: accountId,
        serverURL: "https://private-sync.example",
        sessionToken: sessionToken
      )
    )

    let json = try XCTUnwrap(
      String(data: AddressAtlasExporter.json(for: document), encoding: .utf8))

    XCTAssertFalse(json.contains("syncState"))
    XCTAssertFalse(json.contains("sessionToken"))
    XCTAssertFalse(json.contains(sessionToken))
    XCTAssertFalse(json.contains("encryptedCredentials"))
    XCTAssertFalse(json.contains(envelope.ciphertext))
    XCTAssertFalse(json.contains(credentialCanary))
    XCTAssertFalse(json.contains("lastError"))
    XCTAssertFalse(json.contains("raw-provider-error-marker"))
    XCTAssertTrue(json.contains("Binance"))
    XCTAssertTrue(json.contains("verifiedReadOnly"))
  }
}
