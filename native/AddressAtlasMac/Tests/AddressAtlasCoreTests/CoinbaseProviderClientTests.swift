import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class CoinbaseProviderClientTests: XCTestCase {
  func testCoinbasePaginatesAccountsAndSignsEveryPage() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"11111111-1111-4111-8111-111111111111","currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"uuid":"22222222-2222-4222-8222-222222222222","currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}},{"uuid":"33333333-3333-4333-8333-333333333333","currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )
    let recorded = requests.snapshot()

    XCTAssertEqual(balance.total["BTC"], 1)
    XCTAssertEqual(balance.total["USDC"], 10)
    XCTAssertEqual(recorded.count, 2)
    XCTAssertNil(
      URLComponents(url: recorded[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "cursor" }))
    XCTAssertEqual(
      URLComponents(url: recorded[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "cursor" })?.value,
      "next-page"
    )
    XCTAssertNotEqual(
      recorded[0].value(forHTTPHeaderField: "Authorization"),
      recorded[1].value(forHTTPHeaderField: "Authorization")
    )
  }

  func testCoinbaseDeduplicatesRepeatedAccountUUIDAcrossPages() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"uuid":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.free["BTC"], 0.25)
    XCTAssertEqual(balance.total["USDC"], 10)
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(
      balance.warnings.contains {
        $0.contains("repeated 1 identical account record") && $0.contains("double-counting")
      })
  }

  func testCoinbaseExcludesEveryConflictingVersionOfRepeatedAccountUUID() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"uuid":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","currency":"BTC","available_balance":{"value":"500"},"hold":{"value":"0"}},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertNil(balance.total["BTC"])
    XCTAssertNil(balance.free["BTC"])
    XCTAssertEqual(balance.total["USDC"], 10)
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(
      balance.warnings.contains {
        $0.contains("conflicting data for 1 repeated account UUID")
          && $0.contains("every version")
          && $0.contains("deterministic")
      })
  }

  func testCoinbaseSkipsMissingOrMalformedAccountUUIDsWithWarning() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"accounts":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","currency":"BTC","available_balance":{"value":"1"},"hold":{"value":"0"}},{"currency":"ETH","available_balance":{"value":"2"},"hold":{"value":"0"}},{"uuid":"not-a-uuid","currency":"SOL","available_balance":{"value":"3"},"hold":{"value":"0"}},{"uuid":42,"currency":"DOGE","available_balance":{"value":"4"},"hold":{"value":"0"}},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","currency":"USDC","available_balance":{"value":"5"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { "one-page" }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total, ["BTC": 1, "USDC": 5])
    XCTAssertEqual(balance.free, ["BTC": 1, "USDC": 5])
    XCTAssertTrue(
      balance.warnings.contains {
        $0.contains("3 account record") && $0.contains("missing or malformed UUID")
      })
  }

  func testCoinbaseKeepsCompletedPagesWhenLaterPageFails() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"11111111-1111-4111-8111-111111111111","currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(request, #"{"error":"temporary"}"#, statusCode: 503)
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertTrue(balance.warnings.contains(where: { $0.contains("completed pages") }))
  }

  func testCoinbaseRejectsOversizedAndControlCharacterCurrenciesBeforeAggregation() async throws {
    let oversizedSymbol = String(repeating: "A", count: 65)
    let controlSymbol = "BTC\rINJECTED"
    let http = ScannerHTTPStub { request in
      let payload: [String: Any] = [
        "accounts": [
          [
            "uuid": "11111111-1111-4111-8111-111111111111",
            "currency": oversizedSymbol,
            "available_balance": ["value": "1"],
            "hold": ["value": "0"],
          ],
          [
            "uuid": "22222222-2222-4222-8222-222222222222",
            "currency": controlSymbol,
            "available_balance": ["value": "2"],
            "hold": ["value": "0"],
          ],
          [
            "uuid": "33333333-3333-4333-8333-333333333333",
            "currency": "usdc",
            "available_balance": ["value": "3"],
            "hold": ["value": "0"],
          ],
        ],
        "has_next": false,
      ]
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { "symbol-validation" }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total, ["USDC": 3])
    XCTAssertEqual(balance.free, ["USDC": 3])
    XCTAssertTrue(
      balance.warnings.contains {
        $0.contains("2 account record") && $0.contains("invalid asset code")
      })
    XCTAssertFalse(balance.warnings.joined().contains(oversizedSymbol))
    XCTAssertFalse(balance.warnings.joined().contains("\r"))
  }

}
