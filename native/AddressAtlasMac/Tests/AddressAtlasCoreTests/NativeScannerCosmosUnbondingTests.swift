import Foundation
import XCTest

@testable import AddressAtlasCore

private let cosmosAddress = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
private let otherCosmosAddress = "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu"

private func utc(_ text: String) -> Date {
  ISO8601DateFormatter().date(from: text)!
}

private func unbondingEntryJSON(balance: String, completion: String?) -> String {
  let time = completion.map { "\"completion_time\":\"\($0)\"," } ?? ""
  return
    "{\"creation_height\":\"90\",\(time)\"initial_balance\":\"\(balance)\",\"balance\":\"\(balance)\",\"unbonding_id\":\"7\"}"
}

private func unbondingRecordJSON(
  validator: String,
  entries: [String],
  delegator: String = cosmosAddress
) -> String {
  "{\"delegator_address\":\"\(delegator)\",\"validator_address\":\"\(validator)\",\"entries\":[\(entries.joined(separator: ","))]}"
}

private func unbondingPageJSON(_ records: [String], nextKey: String? = nil) -> String {
  let key = nextKey.map { "\"\($0)\"" } ?? "null"
  return "{\"unbonding_responses\":[\(records.joined(separator: ","))],\"pagination\":{\"next_key\":\(key)}}"
}

private let cosmosHeaders = ["x-cosmos-block-height": "123"]

/// Cosmos Hub at height 123 (the stub serves the latest-block lookup itself),
/// 1 ATOM liquid, no delegations, no rewards, and whatever the test returns
/// for unbonding delegations.
private func cosmosStub(
  requests: ScannerRequestLog? = nil,
  unbonding: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
) -> ScannerHTTPStub {
  ScannerHTTPStub { request in
    requests?.append(request)
    let path = request.url?.path ?? ""
    if path.hasSuffix("/unbonding_delegations") { return try unbonding(request) }
    if path.contains("/cosmos/bank/") {
      return scannerResponse(
        request, #"{"balances":[{"denom":"uatom","amount":"1000000"}]}"#,
        headerFields: cosmosHeaders)
    }
    if path.contains("/cosmos/staking/") {
      return scannerResponse(request, #"{"delegation_responses":[]}"#, headerFields: cosmosHeaders)
    }
    return scannerResponse(request, #"{"total":[]}"#, headerFields: cosmosHeaders)
  }
}

private func cosmosScanner(
  http: ScannerHTTPStub,
  maxCosmosPages: Int = 20
) -> NativeScanner {
  NativeScanner(
    http: JSONHTTPClient(http: http),
    priceProvider: ScannerStaticPriceProvider(values: ["cosmos": PricePoint(usd: 5)]),
    maxCosmosPages: maxCosmosPages
  )
}

final class NativeScannerCosmosUnbondingTests: XCTestCase {
  // MARK: Parsing

  private func parse(_ page: String, decimals: Int = 6) throws -> CosmosUnbondingParse? {
    let response = try JSONDecoder().decode(
      CosmosUnbondingResponse.self, from: Data(page.utf8))
    return NativeScanner.parseCosmosUnbonding(response, decimals: decimals)
  }

  func testEntriesSharingACompletionTimeAreSummedAndBucketsComeSoonestFirst() throws {
    let page = unbondingPageJSON([
      unbondingRecordJSON(
        validator: "cosmosvaloper1a",
        entries: [
          unbondingEntryJSON(balance: "4990000", completion: "2026-11-20T08:30:00.5Z"),
          unbondingEntryJSON(balance: "10000000", completion: "2026-11-16T12:00:00.123456789Z"),
        ]),
      unbondingRecordJSON(
        validator: "cosmosvaloper1b",
        entries: [unbondingEntryJSON(balance: "2000000", completion: "2026-11-16T12:00:00Z")]),
    ])

    let parsed = try XCTUnwrap(try parse(page))

    XCTAssertEqual(
      parsed.buckets,
      [
        CosmosUnbondingBucket(unlocksAt: utc("2026-11-16T12:00:00Z"), amount: 12),
        CosmosUnbondingBucket(unlocksAt: utc("2026-11-20T08:30:00Z"), amount: 4.99),
      ])
    XCTAssertTrue(parsed.warnings.isEmpty)
    for bucket in parsed.buckets {
      let seconds = try XCTUnwrap(bucket.unlocksAt).timeIntervalSince1970
      XCTAssertEqual(seconds, seconds.rounded(.down), "persisted dates are whole seconds")
    }
  }

  func testUnbondingUsesTheEntryBalanceAfterSlashingAndSkipsEmptyEntries() throws {
    let slashed =
      "{\"creation_height\":\"1\",\"completion_time\":\"2026-11-16T12:00:00Z\",\"initial_balance\":\"1000000\",\"balance\":\"950000\"}"
    let page = unbondingPageJSON([
      unbondingRecordJSON(
        validator: "cosmosvaloper1a",
        entries: [
          slashed,
          unbondingEntryJSON(balance: "0", completion: "2026-11-17T12:00:00Z"),
        ])
    ])

    let parsed = try XCTUnwrap(try parse(page))

    XCTAssertEqual(parsed.buckets.map(\.amount), [0.95])
  }

  func testAMissingOrUnusableCompletionTimeStillCountsInAnUndatedBucketWithAWarning() throws {
    let unusable = [
      "2026-02-30T12:00:00Z",  // Foundation would silently move this to March.
      "2026-11-16T24:00:00Z",
      "2026-11-16T12:00:60Z",  // leap second
      "2026-11-16T12:00:00+01:00",  // the SDK only emits UTC
      "2026-11-16 12:00:00Z",
      "2026-11-16T12:00:00.Z",
      "1969-12-31T23:59:59Z",
      "0001-01-01T00:00:00Z",  // Go's zero time
      "soon",
      "",
    ]
    var entries = unusable.map { unbondingEntryJSON(balance: "1000000", completion: $0) }
    entries.append(unbondingEntryJSON(balance: "1000000", completion: nil))
    let page = unbondingPageJSON([
      unbondingRecordJSON(validator: "cosmosvaloper1a", entries: entries)
    ])

    let parsed = try XCTUnwrap(try parse(page))

    XCTAssertEqual(parsed.buckets, [CosmosUnbondingBucket(unlocksAt: nil, amount: 11)])
    XCTAssertEqual(
      parsed.warnings,
      [
        "11 unbonding entries have no usable completion time. They're counted, but without an unlock date."
      ])
  }

  func testAnUntrustworthyBalanceFailsTheWholePartInsteadOfUndercounting() throws {
    for balance in ["not-a-number", "1e6", "-5", "0x10", " 5", "1.5", "", "inf", "nan"] {
      let page = unbondingPageJSON([
        unbondingRecordJSON(
          validator: "cosmosvaloper1a",
          entries: [
            unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z"),
            unbondingEntryJSON(balance: balance, completion: "2026-11-17T12:00:00Z"),
          ])
      ])
      XCTAssertNil(try parse(page), "balance \(balance.debugDescription)")
    }
    // A wrongly typed balance is an unusable amount, not a crash.
    let wrongType =
      "{\"unbonding_responses\":[{\"delegator_address\":\"\(cosmosAddress)\",\"validator_address\":\"v\",\"entries\":[{\"completion_time\":\"2026-11-16T12:00:00Z\",\"balance\":5}]}]}"
    XCTAssertNil(try parse(wrongType))
    XCTAssertNil(try parse(unbondingPageJSON([]), decimals: 99))
  }

  func testMoreDistinctCompletionTimesThanTheCapFoldIntoOneBucketThatKeepsTheEarliestOfThem()
    throws
  {
    let cap = NativeScanner.maximumCosmosUnbondingHoldings
    let first = utc("2026-11-01T00:00:00Z")
    // cap + 5 distinct times, one ATOM each, a day apart.
    let entries = (0..<(cap + 5)).map { day -> String in
      let date = first.addingTimeInterval(TimeInterval(day) * 86_400)
      let text = ISO8601DateFormatter().string(from: date)
      return unbondingEntryJSON(balance: "1000000", completion: text)
    }
    let page = unbondingPageJSON([
      unbondingRecordJSON(validator: "cosmosvaloper1a", entries: entries)
    ])

    let parsed = try XCTUnwrap(try parse(page))

    XCTAssertEqual(parsed.buckets.count, cap)
    let folded = try XCTUnwrap(parsed.buckets.last)
    XCTAssertEqual(folded.amount, 6)
    XCTAssertEqual(
      folded.unlocksAt, first.addingTimeInterval(TimeInterval(cap - 1) * 86_400))
    XCTAssertEqual(parsed.buckets.dropLast().map(\.amount), Array(repeating: 1, count: cap - 1))
    XCTAssertEqual(parsed.buckets.map(\.amount).reduce(0, +), Double(cap + 5), accuracy: 1e-9)
    XCTAssertEqual(parsed.warnings.count, 1)
    XCTAssertTrue(parsed.warnings[0].contains("more than \(cap) different completion times"))
  }

  func testCompletionTimeParserAcceptsOnlyStrictUTCRFC3339() {
    let formatter = ISO8601DateFormatter()
    XCTAssertEqual(
      NativeScanner.cosmosCompletionTime("2026-11-16T12:00:00Z", formatter: formatter),
      utc("2026-11-16T12:00:00Z"))
    XCTAssertEqual(
      NativeScanner.cosmosCompletionTime("2024-02-29T23:59:59.999999999Z", formatter: formatter),
      utc("2024-02-29T23:59:59Z"))
    XCTAssertNil(NativeScanner.cosmosCompletionTime("2025-02-29T00:00:00Z", formatter: formatter))
    XCTAssertNil(NativeScanner.cosmosCompletionTime("2026-13-01T00:00:00Z", formatter: formatter))
    XCTAssertNil(NativeScanner.cosmosCompletionTime("2026-11-16T12:00:00", formatter: formatter))
    XCTAssertNil(
      NativeScanner.cosmosCompletionTime(
        "2026-11-16T12:00:00.1234567890123456789012345Z", formatter: formatter))
  }

  // MARK: Scanning

  func testScanTurnsUnbondingEntriesIntoDatedPricedHoldingsThatTheVaultAccepts() async throws {
    let requests = ScannerRequestLog()
    let http = cosmosStub(requests: requests) { request in
      scannerResponse(
        request,
        unbondingPageJSON([
          unbondingRecordJSON(
            validator: "cosmosvaloper1a",
            entries: [
              unbondingEntryJSON(balance: "4990000", completion: "2026-11-16T12:00:00.123456789Z"),
              unbondingEntryJSON(balance: "10000000", completion: "2026-11-16T12:00:00Z"),
            ]),
          unbondingRecordJSON(
            validator: "cosmosvaloper1b",
            entries: [unbondingEntryJSON(balance: "2000000", completion: "2026-11-20T08:30:00Z")]),
        ]),
        headerFields: cosmosHeaders
      )
    }

    let result = try await cosmosScanner(http: http).scan(addresses: cosmosAddress)

    let unbonding = result.holdings.filter { $0.source == .unbonding }
    XCTAssertEqual(unbonding.count, 2)
    XCTAssertEqual(unbonding.map(\.amount), [14.99, 2])
    XCTAssertEqual(
      unbonding.map(\.unlocksAt),
      [utc("2026-11-16T12:00:00Z"), utc("2026-11-20T08:30:00Z")])
    XCTAssertEqual(
      unbonding.map(\.id),
      [
        "\(cosmosAddress)-cosmoshub-ATOM-unbonding-\(Int(utc("2026-11-16T12:00:00Z").timeIntervalSince1970))",
        "\(cosmosAddress)-cosmoshub-ATOM-unbonding-\(Int(utc("2026-11-20T08:30:00Z").timeIntervalSince1970))",
      ])
    for holding in unbonding {
      XCTAssertEqual(holding.symbol, "ATOM")
      XCTAssertEqual(holding.name, "Cosmos Hub Unbonding")
      XCTAssertEqual(holding.family, .cosmos)
      XCTAssertEqual(holding.chainId, "cosmoshub")
      XCTAssertEqual(holding.pricingStatus, .priced)
      XCTAssertEqual(holding.priceUsd, 5)
      XCTAssertEqual(holding.valueUsd, holding.amount * 5, accuracy: 1e-9)
    }
    // Liquid balance is untouched, and nothing warned.
    XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1)
    XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    // A scan with unbonding holdings is a valid vault snapshot.
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets(result.holdings))
    XCTAssertEqual(result.totalUsd, (1 + 14.99 + 2) * 5, accuracy: 1e-9)

    // One request, pinned to the scan's snapshot height, asking for 500.
    let unbondingRequests = requests.snapshot().filter {
      $0.url?.path == "/cosmos/staking/v1beta1/delegators/\(cosmosAddress)/unbonding_delegations"
    }
    XCTAssertEqual(unbondingRequests.count, 1)
    XCTAssertEqual(unbondingRequests[0].value(forHTTPHeaderField: "x-cosmos-block-height"), "123")
    XCTAssertEqual(
      URLComponents(url: unbondingRequests[0].url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pagination.limit" })?.value,
      "500")
  }

  func testUnbondingPaginationFollowsKeysAndSumsEveryPage() async throws {
    let requests = ScannerRequestLog()
    let http = cosmosStub(requests: requests) { request in
      let nextKey = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pagination.key" })?.value
      if nextKey == nil {
        return scannerResponse(
          request,
          unbondingPageJSON(
            [
              unbondingRecordJSON(
                validator: "cosmosvaloper1a",
                entries: [
                  unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z")
                ])
            ], nextKey: "page+/="),
          headerFields: cosmosHeaders)
      }
      XCTAssertEqual(nextKey, "page+/=")
      return scannerResponse(
        request,
        unbondingPageJSON([
          unbondingRecordJSON(
            validator: "cosmosvaloper1b",
            entries: [unbondingEntryJSON(balance: "2500000", completion: "2026-11-16T12:00:00Z")])
        ]),
        headerFields: cosmosHeaders)
    }

    let result = try await cosmosScanner(http: http).scan(addresses: cosmosAddress)

    XCTAssertEqual(result.holdings.filter { $0.source == .unbonding }.map(\.amount), [3.5])
    let queries = requests.snapshot()
      .filter { $0.url?.path.hasSuffix("/unbonding_delegations") == true }
      .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    XCTAssertEqual(queries.count, 2)
    // Base64 keys keep their `+` as %2B on the wire.
    XCTAssertTrue(queries[1].contains("pagination.key=page%2B%2F%3D"), queries[1])
  }

  func testUnbondingPaginationStopsOnARepeatedKeyAndAtThePageLimitWithWarnings() async throws {
    let repeatingPage = unbondingPageJSON(
      [
        unbondingRecordJSON(
          validator: "cosmosvaloper1a",
          entries: [unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z")])
      ], nextKey: "same")
    let repeated = cosmosStub { request in
      scannerResponse(request, repeatingPage, headerFields: cosmosHeaders)
    }
    let repeatedResult = try await cosmosScanner(http: repeated).scan(addresses: cosmosAddress)
    XCTAssertTrue(
      repeatedResult.warnings.contains { $0.contains("repeated a page marker while listing unbonding entries") })

    let counter = ScannerRequestLog()
    let endless = cosmosStub(requests: counter) { request in
      let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pagination.key" })?.value
      let next = "k\((key.flatMap { Int($0.dropFirst()) } ?? 0) + 1)"
      return scannerResponse(
        request,
        unbondingPageJSON(
          [
            unbondingRecordJSON(
              validator: "cosmosvaloper1\(next)",
              entries: [
                unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z")
              ])
          ], nextKey: next),
        headerFields: cosmosHeaders)
    }
    let limited = try await cosmosScanner(http: endless, maxCosmosPages: 3)
      .scan(addresses: cosmosAddress)
    XCTAssertTrue(
      limited.warnings.contains {
        $0.contains("stopped after 3 pages of unbonding entries")
      })
    XCTAssertEqual(limited.holdings.filter { $0.source == .unbonding }.map(\.amount), [3])
    XCTAssertEqual(
      counter.snapshot().filter { $0.url?.path.hasSuffix("/unbonding_delegations") == true }.count,
      3)
  }

  func testALaterUnbondingPageFailureKeepsEarlierPagesAndSaysSo() async throws {
    let http = cosmosStub { request in
      let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pagination.key" })?.value
      if key == nil {
        return scannerResponse(
          request,
          unbondingPageJSON(
            [
              unbondingRecordJSON(
                validator: "cosmosvaloper1a",
                entries: [
                  unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z")
                ])
            ], nextKey: "next"),
          headerFields: cosmosHeaders)
      }
      return scannerResponse(request, "{}", statusCode: 503)
    }

    let result = try await cosmosScanner(http: http).scan(addresses: cosmosAddress)

    XCTAssertEqual(result.holdings.filter { $0.source == .unbonding }.map(\.amount), [1])
    XCTAssertTrue(
      result.warnings.contains {
        $0.contains("Couldn't read later pages of unbonding entries")
      })
  }

  func testAFailedUnbondingLookupIsAWarningNeverASilentAllClear() async throws {
    let failures: [(String, @Sendable (URLRequest) throws -> (Data, HTTPURLResponse))] = [
      ("HTTP 500", { scannerResponse($0, "{}", statusCode: 500) }),
      ("not found", { scannerResponse($0, #"{"code":12,"message":"Not Implemented"}"#, statusCode: 501) }),
      ("garbage", { scannerResponse($0, "<html>blocked</html>", headerFields: cosmosHeaders) }),
      (
        "no height echo",
        { scannerResponse($0, unbondingPageJSON([])) }
      ),
      (
        "wrong height",
        { scannerResponse($0, unbondingPageJSON([]), headerFields: ["x-cosmos-block-height": "124"]) }
      ),
      (
        "invalid amount",
        {
          scannerResponse(
            $0,
            unbondingPageJSON([
              unbondingRecordJSON(
                validator: "cosmosvaloper1a",
                entries: [unbondingEntryJSON(balance: "NaN", completion: "2026-11-16T12:00:00Z")])
            ]), headerFields: cosmosHeaders)
        }
      ),
    ]
    for (name, response) in failures {
      let result = try await cosmosScanner(http: cosmosStub(unbonding: response))
        .scan(addresses: cosmosAddress)

      XCTAssertFalse(result.holdings.contains { $0.source == .unbonding }, name)
      XCTAssertTrue(
        result.warnings.contains { $0.contains(CosmosScanPart.unbonding.failureWarning) },
        "\(name): \(result.warnings)")
      // The rest of the Cosmos scan is intact.
      XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1, name)
    }
  }

  func testUnbondingRecordsAreDeduplicatedAndQuarantinedLikeDelegations() async throws {
    let identical = unbondingRecordJSON(
      validator: "cosmosvaloper1a",
      entries: [unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z")])
    let conflictingA = unbondingRecordJSON(
      validator: "cosmosvaloper1c",
      entries: [unbondingEntryJSON(balance: "3000000", completion: "2026-11-16T12:00:00Z")])
    let conflictingB = unbondingRecordJSON(
      validator: "cosmosvaloper1c",
      entries: [unbondingEntryJSON(balance: "9000000", completion: "2026-11-16T12:00:00Z")])
    let foreign = unbondingRecordJSON(
      validator: "cosmosvaloper1d",
      entries: [unbondingEntryJSON(balance: "7000000", completion: "2026-11-16T12:00:00Z")],
      delegator: otherCosmosAddress)
    let http = cosmosStub { request in
      let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pagination.key" })?.value
      if key == nil {
        return scannerResponse(
          request, unbondingPageJSON([identical, conflictingA, foreign], nextKey: "p2"),
          headerFields: cosmosHeaders)
      }
      return scannerResponse(
        request, unbondingPageJSON([identical, conflictingB]), headerFields: cosmosHeaders)
    }

    let result = try await cosmosScanner(http: http).scan(addresses: cosmosAddress)

    // Only the identical record (once) survives: the conflicting validator and
    // the other delegator's record are dropped, never guessed at.
    XCTAssertEqual(result.holdings.filter { $0.source == .unbonding }.map(\.amount), [1])
    XCTAssertTrue(
      result.warnings.contains { $0.contains("listed the same unbonding entry twice") })
    XCTAssertTrue(
      result.warnings.contains {
        $0.contains("conflicting data for one validator")
      })
    XCTAssertTrue(
      result.warnings.contains {
        $0.contains("One unbonding entry doesn't belong to this wallet")
      })
  }

  func testAnUnbondingEntryWithoutADateStillShowsUpAndWarns() async throws {
    let http = cosmosStub { request in
      scannerResponse(
        request,
        unbondingPageJSON([
          unbondingRecordJSON(
            validator: "cosmosvaloper1a",
            entries: [
              unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z"),
              unbondingEntryJSON(balance: "2000000", completion: nil),
            ])
        ]), headerFields: cosmosHeaders)
    }

    let result = try await cosmosScanner(http: http).scan(addresses: cosmosAddress)

    let unbonding = result.holdings.filter { $0.source == .unbonding }
    XCTAssertEqual(unbonding.map(\.amount), [1, 2])
    XCTAssertEqual(unbonding.map(\.unlocksAt), [utc("2026-11-16T12:00:00Z"), nil])
    XCTAssertEqual(
      unbonding.last?.id, "\(cosmosAddress)-cosmoshub-ATOM-unbonding-undated")
    XCTAssertTrue(
      result.warnings.contains { $0.contains("One unbonding entry has no usable completion time") })
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets(result.holdings))
  }

  func testWithoutAPriceUnbondingHoldingsAreStillListedAsUnpriced() async throws {
    let http = cosmosStub { request in
      scannerResponse(
        request,
        unbondingPageJSON([
          unbondingRecordJSON(
            validator: "cosmosvaloper1a",
            entries: [unbondingEntryJSON(balance: "1000000", completion: "2026-11-16T12:00:00Z")])
        ]), headerFields: cosmosHeaders)
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: cosmosAddress)

    let holding = try XCTUnwrap(result.holdings.first { $0.source == .unbonding })
    XCTAssertEqual(holding.pricingStatus, .unpriced)
    XCTAssertEqual(holding.valueUsd, 0)
    XCTAssertEqual(holding.amount, 1)
    XCTAssertNoThrow(try VaultDocumentSemanticValidator.validateAssets(result.holdings))
  }
}
