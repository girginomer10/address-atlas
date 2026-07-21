import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class KrakenProviderClientTests: XCTestCase {
  func testKrakenInvalidAliasAmountQuarantinesWholeNormalizedAsset() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let http = ScannerHTTPStub { request in
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(
          request,
          #"{"error":[],"result":{"XBT":"1","XXBT":"not-a-number","XETH":"2"}}"#
        )
      }
      return scannerResponse(
        request,
        #"{"error":[],"result":{"XBT":{"altname":"XBT"},"XXBT":{"altname":"XBT"},"XETH":{"altname":"ETH"}}}"#
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "invalid-alias-amount-key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )

    XCTAssertNil(balance.exactTotal["BTC"])
    XCTAssertNil(balance.total["BTC"])
    XCTAssertEqual(balance.exactTotal["ETH"]?.canonicalString, "2")
    XCTAssertTrue(balance.warnings.contains { $0.contains("invalid numeric amounts") })
  }

  func testKrakenRejectsInvalidBalanceCodesAndMetadataAliasesButPreservesKnownSuffixes()
    async throws
  {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let oversizedSymbol = String(repeating: "A", count: 65)
    let controlSymbol = "BTC\nINJECTED"
    let http = ScannerHTTPStub { request in
      let payload: [String: Any]
      if request.url?.path == "/0/private/Balance" {
        payload = [
          "error": [],
          "result": [oversizedSymbol: "1", controlSymbol: "2", "XETH.S": "3"],
        ]
      } else {
        payload = [
          "error": [],
          "result": ["XETH": ["altname": "ETH\nINJECTED"]],
        ]
      }
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "symbol-validation-key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )

    XCTAssertEqual(balance.total, ["ETH": 3])
    XCTAssertTrue(balance.warnings.contains { $0.contains("metadata was unavailable") })
    XCTAssertTrue(
      balance.warnings.contains {
        $0.contains("2 balance record") && $0.contains("invalid asset code")
      })
    XCTAssertFalse(balance.warnings.joined().contains(oversizedSymbol))
    XCTAssertFalse(balance.warnings.joined().contains("\n"))
  }

  func testKrakenUsesAssetMetadataAndPreservesFiatAsUnpriced() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(
          request,
          #"{"error":[],"result":{"XXBT":"0.5","XXLM":"2","XETH.S":"3","ZUSD":"4","ZEUR":"5","USD.M":"6"}}"#
        )
      }
      return scannerResponse(
        request,
        #"{"error":[],"result":{"XXBT":{"altname":"XBT"},"XXLM":{"altname":"XLM"},"XETH":{"altname":"ETH"},"ZUSD":{"altname":"USD"},"ZEUR":{"altname":"EUR"}}}"#
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )
    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )
    let normalized = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: balance,
      id: UUID(),
      provider: .kraken,
      label: "Kraken",
      priceProvider: ScannerStaticPriceProvider(values: [
        "bitcoin": PricePoint(usd: 100_000),
        "ethereum": PricePoint(usd: 3_000),
        "stellar": PricePoint(usd: 0.1),
      ])
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.total["XLM"], 2)
    XCTAssertEqual(balance.total["ETH"], 3)
    XCTAssertEqual(balance.total["USD"], 10)
    XCTAssertEqual(balance.total["EUR"], 5)
    XCTAssertEqual(normalized.holdings.first(where: { $0.symbol == "EUR" })?.priceUsd, 0)
    XCTAssertTrue(normalized.warnings.contains(where: { $0.contains("EUR") }))
    XCTAssertEqual(
      Set(requests.snapshot().compactMap { $0.url?.path }),
      ["/0/private/Balance", "/0/public/Assets"])
  }

  func testKrakenRejectsCaseFoldedAssetAliasCollisionsWithoutTrapOrIncorrectAlias() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{"FOO":"1"}}"#)
      }
      return scannerResponse(
        request,
        #"{"error":[],"result":{"foo":{"altname":"BTC"},"FOO":{"altname":"DOGE"}}}"#
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "alias-collision-key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )

    XCTAssertEqual(balance.total, ["FOO": 1])
    XCTAssertNil(balance.total["BTC"])
    XCTAssertNil(balance.total["DOGE"])
    XCTAssertTrue(balance.warnings.contains { $0.contains("metadata was unavailable") })
    XCTAssertEqual(
      Set(requests.snapshot().compactMap { $0.url?.path }),
      ["/0/private/Balance", "/0/public/Assets"]
    )
  }

}
