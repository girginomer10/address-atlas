import CryptoKit
import XCTest
@testable import AddressAtlasCore

final class ExporterTests: XCTestCase {
  func testShareSafeExportsHaveAClosedSchemaAndOmitSensitiveCanaries() throws {
    let stableID = "11111111-2222-4333-8444-555555555555"
    let address = "0x1234567890abcdef1234567890abcdef12345678"
    let label = "Treasury github_" + "pat_EXAMPLESECRET1234567890"
    let chainID = "private-chain-canary"
    let chainName = "Private Chain Name"
    let symbol = "APIKEY_CANARY"
    let rawName = "Client secret sk-canary-123456789"
    let explorerURL = "https://example.com/private?token=session-canary"
    let warning = "Provider warning with credential AKIA" + "IOSFODNN7EXAMPLE"
    let exactAmount = 123.456
    let exactPrice = 7.25
    let exactValue = exactAmount * exactPrice
    let change = 18.7654
    let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
    let asset = TrackedAsset(
      id: stableID,
      address: address,
      chainId: chainID,
      chainName: chainName,
      family: .evm,
      symbol: symbol,
      name: rawName,
      amount: exactAmount,
      priceUsd: exactPrice,
      valueUsd: exactValue,
      change24h: change,
      explorerUrl: explorerURL,
      source: .native,
      walletLabel: label
    )

    let connectionID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    let credentialEnvelope = try VaultCrypto().sealJSON(
      ExchangeCredentials(
        apiKey: "credential-api-key-canary",
        secret: "credential-secret-canary",
        passphrase: "credential-passphrase-canary"
      ),
      with: SymmetricKey(data: Data(repeating: 0x7A, count: 32)),
      keyId: "exchange-\(connectionID.uuidString)"
    )
    let accountID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let sessionToken = testSessionToken(accountId: accountID)
    let document = VaultDocument(
      preferences: Preferences(dustThreshold: 314.159_265),
      wallets: [
        WalletRecord(
          label: label,
          address: address,
          chainKind: .evm,
          createdAt: timestamp,
          updatedAt: timestamp
        )
      ],
      exchangeConnections: [
        ExchangeConnectionRecord(
          id: connectionID,
          provider: .binance,
          label: "Exchange label credential-canary",
          encryptedCredentials: credentialEnvelope,
          createdAt: timestamp,
          updatedAt: timestamp
        )
      ],
      scanRuns: [
        ScanRunRecord(
          generatedAt: timestamp,
          totalUsd: exactValue,
          inputCount: 1,
          holdings: [asset],
          warnings: [warning]
        )
      ],
      syncState: SyncState(
        accountId: accountID,
        serverURL: "https://session-canary.example",
        sessionToken: sessionToken,
        latestRemoteVersion: 1,
        lastSyncedAt: timestamp,
        lastChecksum: String(repeating: "a", count: 64),
        lastSyncedContentChecksum: String(repeating: "b", count: 64)
      ),
      updatedAt: timestamp
    )

    let jsonData = try AddressAtlasExporter.shareSafeJSON(for: document)
    let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
    let csv = try AddressAtlasExporter.shareSafeCSV(for: document)
    let sensitiveCanaries = [
      stableID,
      address,
      label,
      chainID,
      chainName,
      symbol,
      rawName,
      explorerURL,
      warning,
      String(exactAmount),
      String(exactPrice),
      String(exactValue),
      String(change),
      "2033-05-18T03:33:20Z",
      connectionID.uuidString,
      credentialEnvelope.keyId,
      credentialEnvelope.nonce,
      credentialEnvelope.ciphertext,
      credentialEnvelope.checksum,
      accountID,
      sessionToken,
      "https://session-canary.example",
      "314.159265",
    ]
    for output in [json, csv] {
      for canary in sensitiveCanaries {
        XCTAssertFalse(output.contains(canary), "Leaked sensitive canary: \(canary)")
      }
    }

    XCTAssertTrue(json.contains(ShareSafePortfolioReport.privacyNotice))
    XCTAssertTrue(csv.contains(ShareSafePortfolioReport.privacyNotice))
    XCTAssertTrue(json.contains("not anonymous"))
    XCTAssertTrue(csv.contains("not anonymous"))

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    )
    XCTAssertEqual(
      Set(object.keys),
      Set(["exportFormatVersion", "privacyNotice", "groups"])
    )
    let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(
      Set(try XCTUnwrap(groups.first).keys),
      Set([
        "family",
        "source",
        "pricingStatus",
        "holdingCountRange",
        "estimatedValueUsdRange",
      ])
    )
    XCTAssertEqual(
      csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[0],
      "privacy_notice,family,source,pricing_status,holding_count_range,estimated_value_usd_range"
    )
  }

  func testShareSafeAggregationAndBucketingAreDeterministic() throws {
    let priced = (0..<5).map { index in
      shareSafeAsset(
        id: "priced-\(index)",
        source: .erc20,
        priceUsd: 250,
        valueUsd: 250,
        pricingStatus: .priced
      )
    }
    let unpriced = (0..<2).map { index in
      shareSafeAsset(
        id: "unpriced-\(index)",
        source: .native,
        priceUsd: 0,
        valueUsd: 0,
        pricingStatus: .unpriced
      )
    }
    let holdings = priced + unpriced
    let forward = VaultDocument(
      scanRuns: [
        ScanRunRecord(totalUsd: 1_250, inputCount: 0, holdings: holdings)
      ]
    )
    let reversed = VaultDocument(
      scanRuns: [
        ScanRunRecord(totalUsd: 1_250, inputCount: 0, holdings: holdings.reversed())
      ]
    )

    let first = try AddressAtlasExporter.shareSafeReport(for: forward)
    let second = try AddressAtlasExporter.shareSafeReport(for: reversed)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.groups.count, 2)
    XCTAssertEqual(first.groups[0].family, .evm)
    XCTAssertEqual(first.groups[0].source, .erc20)
    XCTAssertEqual(first.groups[0].pricingStatus, .priced)
    XCTAssertEqual(first.groups[0].holdingCountRange, .threeToFive)
    XCTAssertEqual(
      first.groups[0].estimatedValueUsdRange,
      .oneThousandToNineThousandNineHundredNinetyNine
    )
    XCTAssertEqual(first.groups[1].source, .native)
    XCTAssertEqual(first.groups[1].pricingStatus, .unpriced)
    XCTAssertEqual(first.groups[1].holdingCountRange, .oneToTwo)
    XCTAssertEqual(first.groups[1].estimatedValueUsdRange, .notAvailable)
  }

  func testShareSafeReportUsesOnlyTheLatestScanRatherThanLeakingHistoryComposition() throws {
    let oldHolding = shareSafeAsset(
      id: "old-history-canary",
      source: .erc20,
      priceUsd: 25,
      valueUsd: 25,
      pricingStatus: .priced
    )
    let latestHolding = shareSafeAsset(
      id: "latest-holding",
      source: .native,
      priceUsd: 0,
      valueUsd: 0,
      pricingStatus: .unpriced
    )
    let document = VaultDocument(
      scanRuns: [
        ScanRunRecord(
          generatedAt: Date(timeIntervalSince1970: 2_000),
          totalUsd: 0,
          inputCount: 0,
          holdings: [latestHolding]
        ),
        ScanRunRecord(
          generatedAt: Date(timeIntervalSince1970: 1_000),
          totalUsd: 25,
          inputCount: 0,
          holdings: [oldHolding],
          warnings: ["old-history-warning-canary"]
        ),
      ]
    )

    let report = try AddressAtlasExporter.shareSafeReport(for: document)
    let json = String(
      decoding: try AddressAtlasExporter.shareSafeJSON(for: document),
      as: UTF8.self
    )

    XCTAssertEqual(report.groups.count, 1)
    XCTAssertEqual(report.groups[0].source, .native)
    XCTAssertEqual(report.groups[0].pricingStatus, .unpriced)
    XCTAssertFalse(json.contains("old-history-canary"))
    XCTAssertFalse(json.contains("old-history-warning-canary"))
    XCTAssertFalse(json.contains(AssetSource.erc20.rawValue))
  }

  func testShareSafeBucketBoundariesStayCoarse() {
    XCTAssertEqual(ShareSafeHoldingCountRange(count: 1), .oneToTwo)
    XCTAssertEqual(ShareSafeHoldingCountRange(count: 2), .oneToTwo)
    XCTAssertEqual(ShareSafeHoldingCountRange(count: 3), .threeToFive)
    XCTAssertEqual(ShareSafeHoldingCountRange(count: 6), .sixToTen)
    XCTAssertEqual(ShareSafeHoldingCountRange(count: 11), .elevenToTwentyFive)
    XCTAssertEqual(ShareSafeHoldingCountRange(count: 26), .twentySixOrMore)

    XCTAssertEqual(ShareSafeUSDValueRange(pricedValue: nil), .notAvailable)
    XCTAssertEqual(ShareSafeUSDValueRange(pricedValue: 99.99), .underOneHundred)
    XCTAssertEqual(
      ShareSafeUSDValueRange(pricedValue: 100),
      .oneHundredToNineHundredNinetyNine
    )
    XCTAssertEqual(
      ShareSafeUSDValueRange(pricedValue: 1_000),
      .oneThousandToNineThousandNineHundredNinetyNine
    )
    XCTAssertEqual(
      ShareSafeUSDValueRange(pricedValue: 10_000),
      .tenThousandToNinetyNineThousandNineHundredNinetyNine
    )
    XCTAssertEqual(
      ShareSafeUSDValueRange(pricedValue: 100_000),
      .oneHundredThousandToNineHundredNinetyNineThousandNineHundredNinetyNine
    )
    XCTAssertEqual(ShareSafeUSDValueRange(pricedValue: 1_000_000), .oneMillionOrMore)
  }

  func testCSVQuotesCarriageReturnAndCRLFFields() throws {
    let csv = try AddressAtlasExporter.csv(
      for: [asset(walletLabel: "Treasury\rDesk", chainName: "Chain\r\nNetwork")]
    )

    XCTAssertTrue(csv.contains("\"Treasury\rDesk\""))
    XCTAssertTrue(csv.contains("\"Chain\r\nNetwork\""))
  }

  func testCSVNeutralizesFormulaMarkersAtCellAndEmbeddedRecordStarts() throws {
    let csv = try AddressAtlasExporter.csv(
      for: [
        asset(
          walletLabel: "=HYPERLINK(\"https://example.invalid\")",
          chainName: "Safe\r+SUM(1,1)",
          symbol: "SAFE\n@COMMAND",
          name: "Safe\r\n-DANGER"
        )
      ]
    )

    XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"https://example.invalid\"\")\""))
    XCTAssertTrue(csv.contains("\"Safe\r'+SUM(1,1)\""))
    XCTAssertTrue(csv.contains("\"SAFE\n'@COMMAND\""))
    XCTAssertTrue(csv.contains("\"Safe\r\n'-DANGER\""))
  }

  func testCSVLeavesUnknownValuationBlankAndPreservesKnownZero() throws {
    let unpriced = asset(
      walletLabel: "Unknown",
      priceUsd: 0,
      valueUsd: 0,
      pricingStatus: .unpriced
    )
    let knownZero = asset(
      walletLabel: "Known zero",
      priceUsd: 0,
      valueUsd: 0,
      pricingStatus: .priced
    )

    let csv = try AddressAtlasExporter.csv(for: [unpriced, knownZero])
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    XCTAssertEqual(
      lines[0],
      "wallet_or_exchange,chain,symbol,name,amount,price_usd,value_usd,pricing_status,source"
    )
    XCTAssertTrue(lines[1].contains(",1.0,,,unpriced,native"))
    XCTAssertTrue(lines[2].contains(",1.0,0.0,0.0,priced,native"))
  }

  private func asset(
    walletLabel: String,
    chainName: String = "Ethereum",
    symbol: String = "TEST",
    name: String = "Test Token",
    priceUsd: Double = 2,
    valueUsd: Double = 2,
    pricingStatus: AssetPricingStatus? = nil
  ) -> TrackedAsset {
    TrackedAsset(
      id: "test-\(walletLabel)",
      address: "0x0000000000000000000000000000000000000001",
      chainId: "ethereum",
      chainName: chainName,
      family: .evm,
      symbol: symbol,
      name: name,
      amount: 1,
      priceUsd: priceUsd,
      valueUsd: valueUsd,
      pricingStatus: pricingStatus,
      source: .native,
      walletLabel: walletLabel
    )
  }

  private func shareSafeAsset(
    id: String,
    source: AssetSource,
    priceUsd: Double,
    valueUsd: Double,
    pricingStatus: AssetPricingStatus
  ) -> TrackedAsset {
    TrackedAsset(
      id: id,
      address: "0x0000000000000000000000000000000000000001",
      chainId: "user-controlled-chain-id-\(id)",
      chainName: "User controlled chain name \(id)",
      family: .evm,
      symbol: "SYMBOL_\(id)",
      name: "User controlled asset name \(id)",
      amount: 1,
      priceUsd: priceUsd,
      valueUsd: valueUsd,
      pricingStatus: pricingStatus,
      source: source,
      walletLabel: "User controlled label \(id)"
    )
  }
}
