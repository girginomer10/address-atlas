import Foundation
import XCTest

@testable import AddressAtlasCore

final class VaultDocumentSemanticValidatorTests: XCTestCase {
  private let account = "12121212-1212-4212-8212-121212121212"
  private let address = "0x0000000000000000000000000000000000000001"

  func testSessionTokenRequiresCanonicalServerShapeAndBindsAccount() throws {
    let token = testSessionToken(accountId: account)

    XCTAssertTrue(SyncSessionToken.isValid(token))
    XCTAssertTrue(SyncSessionToken.isValid(token, forAccountId: account))
    XCTAssertFalse(
      SyncSessionToken.isValid(
        token,
        forAccountId: "34343434-3434-4434-8434-343434343434"
      )
    )
    XCTAssertFalse(SyncSessionToken.isValid("header-safe-but-not-a-session-token"))

    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    let noncanonicalSignature = String(parts[3]) + "="
    XCTAssertFalse(
      SyncSessionToken.isValid(
        "\(parts[0]).\(parts[1]).\(parts[2]).\(noncanonicalSignature)"
      )
    )
  }

  func testSessionTokenUsabilityIsFalseAtAndAfterExpiryAndDecodeClearsIt() throws {
    let token = sessionToken(issuedAt: 1_000_000, expiresAt: 2_000_000)
    XCTAssertTrue(
      SyncSessionToken.isUsable(
        token,
        forAccountId: account,
        at: Date(timeIntervalSince1970: 1_999.999)
      )
    )
    XCTAssertFalse(
      SyncSessionToken.isUsable(
        token,
        forAccountId: account,
        at: Date(timeIntervalSince1970: 2_000)
      )
    )
    XCTAssertFalse(
      SyncSessionToken.isUsable(
        token,
        forAccountId: account,
        at: Date(timeIntervalSince1970: 2_001)
      )
    )

    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let expired = sessionToken(
      issuedAt: now - SyncSessionToken.maximumLifetimeMilliseconds,
      expiresAt: now - 1
    )
    let state = SyncState(
      accountId: account,
      serverURL: "https://sync.example",
      sessionToken: expired
    )
    let decoded = try JSONDecoder.addressAtlas.decode(
      SyncState.self,
      from: JSONEncoder.addressAtlas.encode(state)
    )
    XCTAssertEqual(decoded.accountId, account)
    XCTAssertTrue(decoded.sessionToken.isEmpty)
  }

  func testLocalAndRemoteSyncContextsAreNotInterchangeable() throws {
    var local = VaultDocument()
    XCTAssertTrue(
      local.syncState.connect(
        accountId: account,
        serverURL: "https://sync.example",
        sessionToken: testSessionToken(accountId: account)
      )
    )
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validate(local))
    XCTAssertThrowsError(
      try VaultDocumentSemanticValidator.validate(
        local,
        context: .remoteSnapshot(accountId: account)
      )
    )

    local.syncState.serverURL = ""
    local.syncState.sessionToken = ""
    XCTAssertNoThrow(
      try VaultDocumentSemanticValidator.validate(
        local,
        context: .remoteSnapshot(accountId: account)
      )
    )
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(local))
  }

  func testInvalidWalletAndAmbiguousExchangeWalletFailClosed() {
    for wallet in [
      WalletRecord(label: "Bad", address: "not-an-address", chainKind: .evm),
      WalletRecord(label: "Exchange", address: address, chainKind: .exchange),
    ] {
      XCTAssertThrowsError(
        try VaultDocumentSemanticValidator.validate(VaultDocument(wallets: [wallet]))
      )
    }
  }

  func testTextContractAcceptsMultibyteLabelsAndRejectsControls() throws {
    let emojiLabel = String(repeating: "😀", count: VaultTextLimits.walletLabelCharacters)
    XCTAssertNoThrow(
      try VaultDocumentSemanticValidator.validate(
        VaultDocument(wallets: [
          WalletRecord(label: emojiLabel, address: address, chainKind: .evm)
        ])
      )
    )
    XCTAssertThrowsError(
      try VaultDocumentSemanticValidator.validate(
        VaultDocument(wallets: [
          WalletRecord(label: "Treasury\u{202E}txt", address: address, chainKind: .evm)
        ])
      )
    )
  }

  func testScanTotalWarningsAndManualReferencesAreCanonical() throws {
    let holdingID = UUID()
    let holding = ManualHoldingRecord(
      id: holdingID,
      label: "Manual",
      provider: "custom",
      customVenue: "Manual",
      symbol: "BTC",
      name: "BTC",
      amount: 1,
      priceUsd: 5,
      valueUsd: 5
    )
    let asset = TrackedAsset(
      id: "manual-\(holdingID.uuidString)",
      address: "Manual",
      chainId: "manual-custom",
      chainName: "Manual",
      family: .exchange,
      symbol: "BTC",
      name: "BTC",
      amount: 1,
      priceUsd: 5,
      valueUsd: 5,
      source: .exchange
    )
    let valid = VaultDocument(
      manualHoldings: [holding],
      scanRuns: [
        ScanRunRecord(totalUsd: 5, inputCount: 0, holdings: [asset], warnings: ["Safe warning"])
      ]
    )
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validate(valid))

    var badTotal = valid
    badTotal.scanRuns[0].totalUsd = 4
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(badTotal))
    var badReference = valid
    badReference.scanRuns[0].holdings[0].chainId = "manual-other"
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(badReference))
    var mismatchedAmount = valid
    mismatchedAmount.scanRuns[0].holdings[0].amount = 2
    mismatchedAmount.scanRuns[0].holdings[0].valueUsd = 10
    mismatchedAmount.scanRuns[0].totalUsd = 10
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(mismatchedAmount))
    var unsafeExplorer = valid
    unsafeExplorer.scanRuns[0].holdings[0].explorerUrl = "javascript:alert(1)"
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(unsafeExplorer))
    var failedHolding = valid
    failedHolding.scanRuns[0].holdings[0].status = .failed
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(failedHolding))
    var duplicateWarnings = valid
    duplicateWarnings.scanRuns[0].warnings = ["Safe warning", "Safe warning"]
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(duplicateWarnings))
  }

  func testExchangeEnvelopeAndDecryptedCredentialPayloadAreBoundToConnection() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let connectionID = UUID()
    let envelope = try ExchangeCredentialVault(crypto: crypto).seal(
      ExchangeCredentials(apiKey: "api-key", secret: "secret"),
      vaultKey: vaultKey,
      connectionId: connectionID
    )
    let document = VaultDocument(exchangeConnections: [
      ExchangeConnectionRecord(
        id: connectionID,
        provider: .binance,
        label: "Binance",
        encryptedCredentials: envelope,
        credentialScopeAssurance: .verifiedReadOnly
      )
    ])
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validate(document))
    XCTAssertNoThrow(
      try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(
        in: document,
        vaultKey: vaultKey,
        crypto: crypto
      )
    )

    var rebound = document
    rebound.exchangeConnections[0].id = UUID()
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validate(rebound))

    let otherKey = try crypto.generateVaultKey()
    XCTAssertThrowsError(
      try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(
        in: document,
        vaultKey: otherKey,
        crypto: crypto
      )
    )

    let duplicateID = UUID()
    let duplicateEnvelope = try ExchangeCredentialVault(crypto: crypto).seal(
      ExchangeCredentials(apiKey: "api-key", secret: "different-secret"),
      vaultKey: vaultKey,
      connectionId: duplicateID
    )
    let duplicate = VaultDocument(exchangeConnections: document.exchangeConnections + [
      ExchangeConnectionRecord(
        id: duplicateID,
        provider: .binance,
        label: "Duplicate Binance",
        encryptedCredentials: duplicateEnvelope,
        credentialScopeAssurance: .verifiedReadOnly
      )
    ])
    XCTAssertThrowsError(
      try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(
        in: duplicate,
        vaultKey: vaultKey,
        crypto: crypto
      )
    )
  }

  func testProviderHoldingIdentityIsDeterministicAndSelfCoherent() throws {
    let connectionID = UUID()
    let asset = TrackedAsset(
      id: "\(connectionID.uuidString)-binance-BTC",
      address: "Primary Binance",
      chainId: "binance",
      chainName: "Binance",
      family: .exchange,
      symbol: "BTC",
      name: "BTC",
      amount: 1,
      priceUsd: 5,
      valueUsd: 5,
      source: .exchange,
      walletLabel: "Primary Binance",
      exchangeId: connectionID,
      exchangeProvider: .binance
    )
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets([asset]))

    var rebound = asset
    rebound.id = "different"
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validateAssets([rebound]))
  }

  func testCurrentSchemaRequiresNonOptionalSyncShapeButSchemaOneMigrates() throws {
    let encoded = try JSONEncoder.addressAtlas.encode(VaultDocument())
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var sync = try XCTUnwrap(object["syncState"] as? [String: Any])
    sync.removeValue(forKey: "serverURL")
    object["syncState"] = sync
    let missingCurrentField = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder.addressAtlas.decode(VaultDocument.self, from: missingCurrentField)
    )

    let legacy = Data(#"{"schemaVersion":1,"wallets":[],"updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
    XCTAssertNoThrow(try JSONDecoder.addressAtlas.decode(VaultDocument.self, from: legacy))
  }


  private func sessionToken(issuedAt: Int64, expiresAt: Int64) -> String {
    let payload: [String: Any] = [
      "userId": account,
      "sessionId": "56565656-5656-4656-8656-565656565656",
      "issuedAt": issuedAt,
      "expiresAt": expiresAt,
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "v1.session.\(Base64URL.encode(data)).\(Base64URL.encode(Data(repeating: 0x3C, count: 32)))"
  }
}
