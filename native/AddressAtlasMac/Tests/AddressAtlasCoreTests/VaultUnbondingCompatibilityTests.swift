import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

/// The unbonding source and the `unlocksAt` field were added without a vault
/// schema bump, so every existing vault must keep decoding, validating,
/// re-encoding, and exporting exactly as before.
final class VaultUnbondingCompatibilityTests: XCTestCase {
  private let cosmosAddress = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
  private let solanaAddress = "11111111111111111111111111111111"
  private let evmAddress = "0x0000000000000000000000000000000000000001"
  private let unlock = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

  private func holding(
    family: ChainFamily = .cosmos,
    source: AssetSource,
    unlocksAt: Date? = nil,
    id: String? = nil
  ) -> TrackedAsset {
    let address: String
    let chainId: String
    let symbol: String
    switch family {
    case .solana: (address, chainId, symbol) = (solanaAddress, "solana", "SOL")
    case .evm: (address, chainId, symbol) = (evmAddress, "ethereum", "ETH")
    default: (address, chainId, symbol) = (cosmosAddress, "cosmoshub", "ATOM")
    }
    return TrackedAsset(
      id: id ?? "\(address)-\(chainId)-\(symbol)-\(source.rawValue)",
      address: address,
      chainId: chainId,
      chainName: chainId.capitalized,
      family: family,
      symbol: symbol,
      name: "\(chainId.capitalized) \(source.rawValue)",
      amount: 2,
      priceUsd: 5,
      valueUsd: 10,
      source: source,
      walletLabel: "Keplr",
      unlocksAt: unlocksAt
    )
  }

  private func document(_ holdings: [TrackedAsset]) -> VaultDocument {
    VaultDocument(
      scanRuns: [
        ScanRunRecord(
          generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
          totalUsd: Double(holdings.count) * 10,
          inputCount: 1,
          holdings: holdings
        )
      ]
    )
  }

  private func assertAssetRejected(
    _ asset: TrackedAsset, field: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try VaultDocumentSemanticValidator.validateAssets([asset]), file: file, line: line) {
      XCTAssertEqual($0 as? VaultDocumentSemanticError, VaultDocumentSemanticError(field: field), file: file, line: line)
    }
  }

  // MARK: Decoding and encoding

  func testAHoldingSavedByAnOlderBuildDecodesWithNoUnlockTimeAndReEncodesIdentically() throws {
    // Exactly what a build before `unlocksAt` wrote, keys sorted.
    let legacy = """
      {"address":"\(cosmosAddress)","amount":280,"chainId":"cosmoshub","chainName":"Cosmos Hub",\
      "explorerUrl":"","family":"cosmos","id":"\(cosmosAddress)-cosmoshub-ATOM-staked",\
      "name":"Cosmos Hub Staked","priceUsd":5,"pricingStatus":"priced","source":"staked",\
      "status":"ok","symbol":"ATOM","valueUsd":1400,"walletLabel":"Keplr"}
      """

    let decoded = try JSONDecoder.addressAtlas.decode(TrackedAsset.self, from: Data(legacy.utf8))

    XCTAssertNil(decoded.unlocksAt)
    XCTAssertEqual(decoded.source, .staked)
    let reencoded = try JSONEncoder.addressAtlas.encode(decoded)
    XCTAssertEqual(String(decoding: reencoded, as: UTF8.self), legacy)
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets([decoded]))
  }

  func testNilUnlockTimeIsNeverWrittenSoOldAndNewBuildsProduceTheSameBytes() throws {
    for source in [AssetSource.native, .staked, .rewards, .unbonding] {
      let encoded = try JSONEncoder.addressAtlas.encode(holding(source: source))
      XCTAssertFalse(
        String(decoding: encoded, as: UTF8.self).contains("unlocksAt"), source.rawValue)
    }
  }

  func testAnUnbondingHoldingRoundTripsItsUnlockTimeAndCanonicalizesFractionalSeconds() throws {
    let fractional = Date(timeIntervalSince1970: 1_800_000_000.75)
    var original = document([holding(source: .unbonding, unlocksAt: fractional)])
    original.schemaVersion = VaultDocument.currentSchemaVersion

    let key = SymmetricKey(data: Data(repeating: 0x7A, count: 32))
    let envelope = try VaultCrypto().sealJSON(
      original, with: key, keyId: "local-db", schemaVersion: original.schemaVersion)
    let reopened = try VaultCrypto().openJSON(VaultDocument.self, envelope: envelope, with: key)

    // The vault persists whole seconds for every date, this one included.
    let unlocked = try XCTUnwrap(reopened.scanRuns[0].holdings[0].unlocksAt)
    XCTAssertEqual(unlocked, unlock)
    XCTAssertEqual(reopened.scanRuns[0].holdings[0].source, .unbonding)
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validate(reopened))
    let json = String(
      decoding: try JSONEncoder.addressAtlas.encode(reopened.scanRuns[0].holdings[0]),
      as: UTF8.self)
    XCTAssertTrue(json.contains("\"unlocksAt\":\"2027-01-15T08:00:00Z\""), json)
    XCTAssertTrue(json.contains("\"source\":\"unbonding\""), json)
  }

  func testUnlockTimesAcceptTheServersFractionalSpellingToo() throws {
    let json = """
      {"address":"\(cosmosAddress)","amount":2,"chainId":"cosmoshub","chainName":"Cosmos Hub",\
      "explorerUrl":"","family":"cosmos","id":"x","name":"n","priceUsd":5,"pricingStatus":"priced",\
      "source":"unbonding","status":"ok","symbol":"ATOM","unlocksAt":"2027-01-15T08:00:00.500Z",\
      "valueUsd":10}
      """

    let decoded = try JSONDecoder.addressAtlas.decode(TrackedAsset.self, from: Data(json.utf8))

    XCTAssertEqual(decoded.unlocksAt, Date(timeIntervalSince1970: 1_800_000_000.5))
  }

  func testAnUnknownFutureSourceStillFailsClosedAtDecodeTime() {
    let json = """
      {"address":"a","amount":2,"chainId":"c","chainName":"C","explorerUrl":"","family":"cosmos",\
      "id":"x","name":"n","priceUsd":5,"source":"vesting","status":"ok","symbol":"ATOM","valueUsd":10}
      """
    XCTAssertThrowsError(try JSONDecoder.addressAtlas.decode(TrackedAsset.self, from: Data(json.utf8)))
  }

  // MARK: Semantic validation

  func testValidatorAcceptsEveryNewAndExistingStakingShape() throws {
    let holdings = [
      holding(source: .staked),
      holding(source: .rewards),
      holding(source: .unbonding, unlocksAt: unlock),
      holding(source: .unbonding, unlocksAt: nil, id: "undated"),
      holding(family: .solana, source: .staked),
      holding(family: .solana, source: .unbonding),
    ]

    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets(holdings))
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validate(document(holdings)))
  }

  func testValidatorKeepsRewardsCosmosOnlyAndStakingOffOtherFamilies() {
    assertAssetRejected(holding(family: .solana, source: .rewards), field: "assets[0].family")
    assertAssetRejected(holding(family: .evm, source: .staked), field: "assets[0].family")
    assertAssetRejected(holding(family: .evm, source: .unbonding), field: "assets[0].family")
    assertAssetRejected(holding(family: .evm, source: .rewards), field: "assets[0].family")
  }

  func testValidatorAllowsAnUnlockTimeOnUnbondingHoldingsOnly() {
    for source in [AssetSource.staked, .rewards, .native] {
      assertAssetRejected(
        holding(source: source, unlocksAt: unlock), field: "assets[0].unlocksAt")
    }
    assertAssetRejected(
      holding(family: .evm, source: .native, unlocksAt: unlock), field: "assets[0].unlocksAt")
  }

  func testValidatorBoundsTheUnlockTimeToWhatTheVaultCanRoundTrip() {
    for seconds in [-1, 253_402_300_800, Double.infinity, -Double.infinity, Double.nan] {
      assertAssetRejected(
        holding(source: .unbonding, unlocksAt: Date(timeIntervalSince1970: seconds)),
        field: "assets[0].unlocksAt")
    }
    for seconds in [0, 1_800_000_000, 253_402_300_799] as [Double] {
      XCTAssertNoThrow(
        try VaultDocumentSemanticValidator.validateAssets([
          holding(source: .unbonding, unlocksAt: Date(timeIntervalSince1970: seconds))
        ]), "\(seconds)")
    }
  }

  func testTheLatestRepresentableUnlockTimeRoundTripsThroughTheVaultEncoder() throws {
    let latest = Date(timeIntervalSince1970: 253_402_300_799)
    let encoded = try JSONEncoder.addressAtlas.encode(
      holding(source: .unbonding, unlocksAt: latest))
    let decoded = try JSONDecoder.addressAtlas.decode(TrackedAsset.self, from: encoded)
    XCTAssertEqual(decoded.unlocksAt, latest)
  }

  // MARK: Exports

  func testFullJSONExportCarriesTheUnlockTimeAndTheShareSaferExportsNeverDo() throws {
    let doc = document([
      holding(source: .unbonding, unlocksAt: unlock),
      holding(source: .staked, id: "staked"),
    ])

    let full = String(decoding: try AddressAtlasExporter.json(for: doc), as: UTF8.self)
    XCTAssertTrue(full.contains("\"unlocksAt\" : \"2027-01-15T08:00:00Z\""), full)
    XCTAssertTrue(full.contains("\"source\" : \"unbonding\""), full)

    let report = try AddressAtlasExporter.shareSafeReport(for: doc)
    XCTAssertEqual(
      Set(report.groups.map(\.source)), [.staked, .unbonding],
      "unbonding is its own coarse group")
    let safeJSON = String(decoding: try AddressAtlasExporter.shareSafeJSON(for: doc), as: UTF8.self)
    let safeCSV = try AddressAtlasExporter.shareSafeCSV(for: doc)
    for output in [safeJSON, safeCSV] {
      XCTAssertFalse(output.contains("unlock"), output)
      XCTAssertFalse(output.contains("2027"), output)
      XCTAssertTrue(output.contains("unbonding"), output)
    }
  }

  func testAUserCanStillExportAVaultThatHasNoUnbondingHoldings() throws {
    let doc = document([holding(source: .staked), holding(family: .evm, source: .native)])

    XCTAssertNoThrow(try AddressAtlasExporter.json(for: doc))
    let csv = try AddressAtlasExporter.csv(for: doc.scanRuns[0].holdings)
    XCTAssertEqual(csv.split(separator: "\n").count, 3)
    XCTAssertTrue(csv.split(separator: "\n")[0].hasSuffix(",source,unlocks_at"))
  }
}
