import Foundation
import XCTest

@testable import AddressAtlasCore

final class ExchangeAmountPrecisionTests: XCTestCase {
  func testExchangeAmountCanonicalizesExactValuesAndRejectsUnsupportedInputs() throws {
    XCTAssertEqual(
      ExchangeAmount(providerString: "+001.2300e2")?.canonicalString,
      "123"
    )
    XCTAssertEqual(
      ExchangeAmount(providerString: "0.00000000000000000000000000000000000001")?
        .canonicalString,
      "0.00000000000000000000000000000000000001"
    )
    XCTAssertNil(ExchangeAmount(providerString: "-1"))
    XCTAssertNil(ExchangeAmount(providerString: " 1"))
    XCTAssertNil(ExchangeAmount(providerString: "NaN"))
    XCTAssertNil(ExchangeAmount(providerString: "1e308"))
    XCTAssertNil(ExchangeAmount(providerString: "123456789012345678901234567890123456789"))
  }

  func testBinancePreservesAmountsBeyondDoubleIntegerPrecisionAndAtHighScale() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"balances":[{"asset":"BTC","free":"9007199254740992","locked":"1"},{"asset":"SHIB","free":"0.123456789012345678901234567890","locked":"0.000000000000000000000000000001"}]}"#
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let balance = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertEqual(balance.exactTotal["BTC"]?.canonicalString, "9007199254740993")
    XCTAssertEqual(balance.exactFree["BTC"]?.canonicalString, "9007199254740992")
    XCTAssertEqual(
      balance.exactTotal["SHIB"]?.canonicalString,
      "0.123456789012345678901234567891"
    )
    XCTAssertEqual(
      balance.exactFree["SHIB"]?.canonicalString,
      "0.12345678901234567890123456789"
    )
    // This compatibility view is intentionally approximate; exact consumers
    // use the authoritative maps above.
    XCTAssertEqual(balance.total["BTC"], 9_007_199_254_740_992)
  }

  func testExactAmountFlowsThroughNormalizationPersistenceAndCSV() throws {
    let canonical = "9007199254740993.123456789012345678901"
    let base = try XCTUnwrap(
      ExchangeAmount(providerString: "9007199254740992.123456789012345678901")
    )
    let increment = try XCTUnwrap(ExchangeAmount(providerString: "1"))
    let balance = ExchangeBalance(exactTotal: ["BTC": base, "XXBT": increment])

    let holding = try XCTUnwrap(
      ExchangeBalanceNormalizer.normalize(
        balance: balance,
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        provider: .binance,
        label: "Binance",
        prices: ["bitcoin": PricePoint(usd: 1)]
      ).first
    )

    XCTAssertEqual(holding.exactAmount, canonical)
    XCTAssertEqual(holding.canonicalAmount, canonical)
    XCTAssertEqual(holding.displayedAmount, canonical)
    XCTAssertTrue(AddressAtlasExporter.csv(for: [holding]).contains(",\(canonical),1.0,"))

    let encoded = try JSONEncoder().encode(holding)
    let decoded = try JSONDecoder().decode(TrackedAsset.self, from: encoded)
    XCTAssertEqual(decoded, holding)
    XCTAssertEqual(decoded.exactAmount, canonical)
  }

  func testLegacyExchangeAssetDecodeMigratesApproximateAmountAndRejectsMismatchedExactValue()
    throws
  {
    let asset = TrackedAsset(
      id: "legacy",
      address: "Binance",
      chainId: "binance",
      chainName: "Binance",
      family: .exchange,
      symbol: "BTC",
      name: "BTC",
      amount: 9_007_199_254_740_992,
      priceUsd: 1,
      valueUsd: 9_007_199_254_740_992,
      source: .exchange,
      exchangeProvider: .binance
    )
    let encoded = try JSONEncoder().encode(asset)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    object.removeValue(forKey: "exactAmount")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let migrated = try JSONDecoder().decode(TrackedAsset.self, from: legacy)
    XCTAssertEqual(migrated.exactAmount, "9007199254740992")
    let migratedJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any]
    )
    XCTAssertEqual(migratedJSON["exactAmount"] as? String, "9007199254740992")

    object["exactAmount"] = "1"
    let inconsistent = try JSONSerialization.data(withJSONObject: object)
    let repaired = try JSONDecoder().decode(TrackedAsset.self, from: inconsistent)
    XCTAssertEqual(repaired.exactAmount, "9007199254740992")
  }
}
