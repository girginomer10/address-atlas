import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class BinanceProviderClientTests: XCTestCase {
  func testBinanceRejectsOversizedAndControlCharacterAssetCodesBeforeAggregation() async throws {
    let oversizedSymbol = String(repeating: "A", count: 65)
    let controlSymbol = "BTC\nINJECTED"
    let http = ScannerHTTPStub { request in
      let payload: [String: Any] = [
        "balances": [
          ["asset": oversizedSymbol, "free": "1", "locked": "0"],
          ["asset": controlSymbol, "free": "2", "locked": "0"],
          ["asset": "eth", "free": "3", "locked": "0"],
        ]
      ]
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
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

    XCTAssertEqual(balance.total, ["ETH": 3])
    XCTAssertEqual(balance.free, ["ETH": 3])
    XCTAssertTrue(balance.warnings.contains { $0.contains("2 account balance record") })
    XCTAssertFalse(balance.warnings.joined().contains(oversizedSymbol))
    XCTAssertFalse(balance.warnings.joined().contains("\n"))
  }

  func testBinanceAggregatesThousandsOfInvalidRecordsAndRejectsFiniteAdditionOverflow() async throws
  {
    var recordBuilder = Array(
      repeating: ["asset": "BTC", "free": "not-a-number", "locked": "0"],
      count: 5_000
    )
    recordBuilder.append(["asset": "ETH", "free": "1e308", "locked": "1e308"])
    let records = recordBuilder
    let http = ScannerHTTPStub { request in
      (
        try JSONSerialization.data(withJSONObject: ["balances": records]),
        scannerHTTPResponse(request)
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

    XCTAssertTrue(balance.total.isEmpty)
    XCTAssertTrue(balance.free.isEmpty)
    XCTAssertEqual(balance.warnings.count, 2)
    XCTAssertTrue(balance.warnings.contains { $0.contains("5000 account balance record") })
    XCTAssertTrue(balance.warnings.contains { $0.contains("ETH") && $0.contains("numeric range") })
    XCTAssertTrue(
      balance.warnings.allSatisfy {
        $0.unicodeScalars.count <= ScanWarningPolicy.maximumScalarCount
      })
  }

  func testBinanceDeduplicatesIdenticalCanonicalBalanceRows() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"balances":[{"asset":"BTC","free":"1","locked":"2"},{"asset":"xbt","free":"1","locked":"2"},{"asset":"ETH","free":"3","locked":"0"}]}"#
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

    XCTAssertEqual(balance.total, ["BTC": 3, "ETH": 3])
    XCTAssertEqual(balance.free, ["BTC": 1, "ETH": 3])
    XCTAssertTrue(balance.warnings.contains(where: { $0.contains("one identical") }))
  }

  func testBinanceRejectsEveryConflictingCanonicalBalanceVersion() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"balances":[{"asset":"BTC","free":"1","locked":"0"},{"asset":"xbt","free":"2","locked":"0"},{"asset":"ETH","free":"3","locked":"0"}]}"#
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

    XCTAssertEqual(balance.total, ["ETH": 3])
    XCTAssertEqual(balance.free, ["ETH": 3])
    XCTAssertTrue(
      balance.warnings.contains(where: { $0.contains("conflicting") && $0.contains("BTC") }))
  }

}
