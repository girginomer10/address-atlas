import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

extension NativeScannerTokenTests {
  func testXrpJsonRpcErrorsDoNotBecomeZeroBalances() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("account_info") {
        let json = """
          {
            "result": {
              "status": "error",
              "error": "internal",
              "error_message": "ledger unavailable"
            }
          }
          """
        return (Data(json.utf8), httpResponse(for: request))
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["ripple": PricePoint(usd: 2)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertTrue(
      result.warnings.contains { warning in
        warning.contains("XRP Ledger") && warning.contains("ledger unavailable")
      })
  }

  func testXrpAccountInfoRejectsWrongEchoedAccountBeforeCreditingBalance() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let wrongAddress = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let ledgerHash = String(repeating: "A", count: 64)
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      guard body["method"] as? String == "account_info" else {
        XCTFail("A rejected account_info response must stop before account_lines.")
        throw URLError(.badServerResponse)
      }
      return scannerResponse(
        request,
        """
        {"result":{"status":"success","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"account_data":{"Account":"\(wrongAddress)","Balance":"1000000"}}}
        """
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertTrue(
      result.warnings.contains { $0.contains("did not match the requested account") },
      result.warnings.joined(separator: "\n")
    )
  }

  func testXrpAccountInfoRequiresExplicitValidatedLedger() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let ledgerHash = String(repeating: "B", count: 64)
    let validationFields = [#""validated":false,"#, ""]

    for validationField in validationFields {
      let http = ScannerHTTPStub { request in
        let body = try scannerJSONObject(request.httpBody ?? Data())
        guard body["method"] as? String == "account_info" else {
          XCTFail("An unvalidated account_info response must stop before account_lines.")
          throw URLError(.badServerResponse)
        }
        return scannerResponse(
          request,
          """
          {"result":{"status":"success",\(validationField)"ledger_hash":"\(ledgerHash)","ledger_index":123,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
          """
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
      )

      let result = try await scanner.scan(addresses: address)

      XCTAssertTrue(result.holdings.isEmpty, validationField)
      XCTAssertTrue(
        result.warnings.contains { $0.contains("did not come from a validated ledger") },
        result.warnings.joined(separator: "\n")
      )
    }
  }

  func testXrpAccountInfoRequiresLedgerHashOrIndex() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      guard body["method"] as? String == "account_info" else {
        XCTFail("An unbound account_info response must stop before account_lines.")
        throw URLError(.badServerResponse)
      }
      return scannerResponse(
        request,
        """
        {"result":{"status":"success","validated":true,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
        """
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertTrue(
      result.warnings.contains { $0.contains("did not identify one validated ledger") },
      result.warnings.joined(separator: "\n")
    )
  }

  func testXrpTrustLinePaginationRejectsAdvancingLedgerAndOmitsPartialIssuedBalances()
    async throws
  {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let firstLedgerHash = String(repeating: "C", count: 64)
    let secondLedgerHash = String(repeating: "D", count: 64)
    let trustLineRequests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      if body["method"] as? String == "account_info" {
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","validated":true,"ledger_hash":"\(firstLedgerHash)","ledger_index":123,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
          """
        )
      }
      let page = trustLineRequests.append(request)
      if page == 1 {
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","account":"\(address)","validated":true,"ledger_hash":"\(firstLedgerHash)","ledger_index":123,"lines":[{"account":"rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv","balance":"2","currency":"USD"}],"marker":{"ledger":123,"seq":1}}}
          """
        )
      }
      return scannerResponse(
        request,
        """
        {"result":{"status":"success","account":"\(address)","validated":true,"ledger_hash":"\(secondLedgerHash)","ledger_index":124,"lines":[{"account":"rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq","balance":"3","currency":"EUR"}]}}
        """
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "XRP" })?.amount, 1)
    XCTAssertFalse(result.holdings.contains(where: { $0.source == .issued }))
    XCTAssertEqual(trustLineRequests.snapshot().count, 2)
    for request in trustLineRequests.snapshot() {
      let body = try scannerJSONObject(request.httpBody ?? Data())
      let params = (body["params"] as? [[String: Any]])?.first
      XCTAssertEqual(params?["ledger_hash"] as? String, firstLedgerHash)
    }
    XCTAssertTrue(
      result.warnings.contains { $0.contains("changed ledger") && $0.contains("incomplete") },
      result.warnings.joined(separator: "\n")
    )
  }

  func testXrpTrustLinePageRejectsEchoedAccountMismatch() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let wrongAddress = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let ledgerHash = String(repeating: "E", count: 64)
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      if body["method"] as? String == "account_info" {
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
          """
        )
      }
      return scannerResponse(
        request,
        """
        {"result":{"status":"success","account":"\(wrongAddress)","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"lines":[{"account":"rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq","balance":"3","currency":"EUR"}]}}
        """
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "XRP" })?.amount, 1)
    XCTAssertFalse(result.holdings.contains(where: { $0.source == .issued }))
    XCTAssertTrue(
      result.warnings.contains { $0.contains("another account") && $0.contains("incomplete") },
      result.warnings.joined(separator: "\n")
    )
  }

  func testXrpTrustLinePageRequiresExplicitValidatedFlag() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let ledgerHash = String(repeating: "F", count: 64)
    let validationFields = [#""validated":false,"#, ""]

    for validationField in validationFields {
      let http = ScannerHTTPStub { request in
        let body = try scannerJSONObject(request.httpBody ?? Data())
        if body["method"] as? String == "account_info" {
          return scannerResponse(
            request,
            """
            {"result":{"status":"success","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
            """
          )
        }
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","account":"\(address)",\(validationField)"ledger_hash":"\(ledgerHash)","ledger_index":123,"lines":[{"account":"rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq","balance":"3","currency":"EUR"}]}}
          """
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
      )

      let result = try await scanner.scan(addresses: address)

      XCTAssertEqual(result.holdings.first(where: { $0.symbol == "XRP" })?.amount, 1)
      XCTAssertFalse(result.holdings.contains(where: { $0.source == .issued }))
      XCTAssertTrue(
        result.warnings.contains { $0.contains("unvalidated page") && $0.contains("incomplete") },
        result.warnings.joined(separator: "\n")
      )
    }
  }

  func testXrpPaginationKeepsExactIndexPinAndValidatesEchoedLedgerHash() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let ledgerHash = String(repeating: "1", count: 64)
    let trustLineRequests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      if body["method"] as? String == "account_info" {
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","validated":true,"ledger_index":123,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
          """
        )
      }
      let page = trustLineRequests.append(request)
      if page == 1 {
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","account":"\(address)","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"lines":[{"account":"rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv","balance":"2","currency":"USD"}],"marker":{"ledger":123,"seq":1}}}
          """
        )
      }
      return scannerResponse(
        request,
        """
        {"result":{"status":"success","account":"\(address)","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"lines":[{"account":"rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq","balance":"3","currency":"EUR"}]}}
        """
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)
    let requestBodies = try trustLineRequests.snapshot().map {
      try scannerJSONObject($0.httpBody ?? Data())
    }
    let firstParams = (requestBodies[0]["params"] as? [[String: Any]])?.first
    let secondParams = (requestBodies[1]["params"] as? [[String: Any]])?.first

    XCTAssertEqual(
      Set(result.holdings.filter { $0.source == .issued }.map(\.symbol)), ["USD", "EUR"])
    XCTAssertEqual(firstParams?["ledger_index"] as? Int, 123)
    XCTAssertNil(firstParams?["ledger_hash"])
    XCTAssertEqual(secondParams?["ledger_index"] as? Int, 123)
    XCTAssertNil(secondParams?["ledger_hash"])
  }

  func testXrpTrustLineParserDecodesIssuedAssets() {
    let lines = [
      XrpTrustLine(
        account: "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv",
        balance: "42.5",
        currency: "5553440000000000000000000000000000000000"
      ),
      XrpTrustLine(
        account: "rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq",
        balance: "-1",
        currency: "IGNORED"
      ),
    ]

    let parsed = NativeScanner.parseXrpTrustLines(
      lines,
      address: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn",
      chain: ChainRegistry.xrp
    )

    XCTAssertEqual(NativeScanner.decodeXrplCurrency("USD"), "USD")
    XCTAssertEqual(
      NativeScanner.decodeXrplCurrency("5553440000000000000000000000000000000000"),
      "HEX:5553440000000000000000000000000000000000"
    )
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(
      parsed.first?.symbol,
      "HEX:5553440000000000000000000000000000000000"
    )
    XCTAssertEqual(parsed.first?.source, .issued)
    XCTAssertEqual(parsed.first?.amount, 42.5)
  }

  func testXrpTrustLineIdentityPreservesDistinct160BitCodesAndExposesLookalike() {
    let hexCodeBeginningWithUSD = "5553440000000000000000000000000000000000"
    let lookalikeUSD = "5553440100000000000000000000000000000000"
    let issuer = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let parsed = NativeScanner.parseXrpTrustLines(
      [
        XrpTrustLine(account: issuer, balance: "1", currency: hexCodeBeginningWithUSD),
        XrpTrustLine(account: issuer, balance: "2", currency: lookalikeUSD),
      ],
      address: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn",
      chain: ChainRegistry.xrp
    )

    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(Set(parsed.map(\.id)).count, 2)
    XCTAssertEqual(parsed[0].symbol, "HEX:\(hexCodeBeginningWithUSD)")
    XCTAssertEqual(parsed[1].symbol, "HEX:\(lookalikeUSD)")
    XCTAssertNotEqual(parsed[0].name, parsed[1].name)
    XCTAssertTrue(parsed[0].id.contains(hexCodeBeginningWithUSD))
    XCTAssertTrue(parsed[1].id.contains(lookalikeUSD))
  }

  func testXrpTrustLineBoundaryDeduplicatesAndRejectsUnsafeOrConflictingRows() {
    let identicalIssuer = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let conflictingIssuer = "rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq"
    let result = NativeScanner.parseXrpTrustLineResult(
      [
        XrpTrustLine(account: identicalIssuer, balance: "2", currency: "USD"),
        XrpTrustLine(account: identicalIssuer, balance: "2.0", currency: "USD"),
        XrpTrustLine(account: conflictingIssuer, balance: "3", currency: "EUR"),
        XrpTrustLine(account: conflictingIssuer, balance: "4", currency: "EUR"),
        XrpTrustLine(account: "not-an-xrp-address", balance: "5", currency: "JPY"),
        XrpTrustLine(account: identicalIssuer, balance: "not-a-number", currency: "GBP"),
      ],
      address: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn",
      chain: ChainRegistry.xrp
    )

    XCTAssertEqual(result.assets.count, 1)
    XCTAssertEqual(result.assets.first?.symbol, "USD")
    XCTAssertEqual(result.assets.first?.amount, 2)
    XCTAssertEqual(
      result.warnings,
      [
        "XRP skipped one trust line with an invalid issuer or currency code.",
        "XRP discarded one issued asset because its trust-line data included an invalid or non-positive balance.",
        "XRP repeated one identical trust line; the duplicate was skipped to avoid double-counting.",
        "XRP returned conflicting balances for one issued asset; every version was skipped.",
      ]
    )
    XCTAssertEqual(NativeScanner.decodeXrplCurrency("XRP"), "")
    XCTAssertEqual(NativeScanner.canonicalXrplCurrencyIdentity("XRP"), "")
  }

  func testXrpMalformedZeroAndNegativeDuplicatesTaintIdentityInEitherOrder() {
    let issuer = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let valid = XrpTrustLine(account: issuer, balance: "2", currency: "USD")

    for rejectedBalance in ["not-a-number", "0", "-1"] {
      let rejected = XrpTrustLine(
        account: issuer,
        balance: rejectedBalance,
        currency: "USD"
      )
      for lines in [[valid, rejected], [rejected, valid]] {
        let result = NativeScanner.parseXrpTrustLineResult(
          lines,
          address: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn",
          chain: ChainRegistry.xrp
        )

        XCTAssertTrue(result.assets.isEmpty, "Expected \(rejectedBalance) to taint USD")
        XCTAssertEqual(
          result.warnings,
          [
            "XRP discarded one issued asset because its trust-line data included an invalid or non-positive balance."
          ]
        )
      }
    }
  }

  func testXrpConflictingDuplicateTaintsIdentityInEitherOrder() {
    let issuer = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let first = XrpTrustLine(account: issuer, balance: "2", currency: "USD")
    let second = XrpTrustLine(account: issuer, balance: "3", currency: "USD")

    for lines in [[first, second], [second, first]] {
      let result = NativeScanner.parseXrpTrustLineResult(
        lines,
        address: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn",
        chain: ChainRegistry.xrp
      )

      XCTAssertTrue(result.assets.isEmpty)
      XCTAssertEqual(
        result.warnings,
        ["XRP returned conflicting balances for one issued asset; every version was skipped."]
      )
    }
  }

  func testXrpTrustLineWarningsUsePluralGrammarForCountTwo() {
    let issuer = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let otherIssuer = "rhub8VRN55s94qWKDv6jmDy1pUykJzF3wq"
    let result = NativeScanner.parseXrpTrustLineResult(
      [
        XrpTrustLine(account: "not-an-xrp-address", balance: "1", currency: "AUD"),
        XrpTrustLine(account: issuer, balance: "1", currency: "XRP"),
        XrpTrustLine(account: issuer, balance: "invalid", currency: "GBP"),
        XrpTrustLine(account: issuer, balance: "0", currency: "JPY"),
        XrpTrustLine(account: issuer, balance: "2", currency: "USD"),
        XrpTrustLine(account: issuer, balance: "2.0", currency: "USD"),
        XrpTrustLine(account: issuer, balance: "2.00", currency: "USD"),
        XrpTrustLine(account: issuer, balance: "3", currency: "EUR"),
        XrpTrustLine(account: issuer, balance: "4", currency: "EUR"),
        XrpTrustLine(account: otherIssuer, balance: "5", currency: "CAD"),
        XrpTrustLine(account: otherIssuer, balance: "6", currency: "CAD"),
      ],
      address: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn",
      chain: ChainRegistry.xrp
    )

    XCTAssertEqual(result.assets.map(\.symbol), ["USD"])
    XCTAssertEqual(
      result.warnings,
      [
        "XRP skipped 2 trust lines with invalid issuers or currency codes.",
        "XRP discarded 2 issued assets because their trust-line data included invalid or non-positive balances.",
        "XRP repeated 2 identical trust lines; the duplicates were skipped to avoid double-counting.",
        "XRP returned conflicting balances for 2 issued assets; every version was skipped.",
      ]
    )
  }
}
