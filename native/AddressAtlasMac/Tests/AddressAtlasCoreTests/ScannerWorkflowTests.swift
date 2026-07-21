import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class ScannerWorkflowTests: XCTestCase {
  func testNativeValuationOverflowRemainsFiniteAndDropsNonFinitePriceChange() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":1e308,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(
        values: ["bitcoin": PricePoint(usd: 1e308, usd24hChange: .infinity)]
      )
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    let holding = try XCTUnwrap(result.holdings.first)

    XCTAssertTrue(holding.amount.isFinite)
    XCTAssertEqual(holding.priceUsd, 1e308)
    XCTAssertEqual(holding.valueUsd, 0)
    XCTAssertNil(holding.change24h)
    XCTAssertEqual(result.totalUsd, 0)
    XCTAssertTrue(result.warnings.contains { $0.contains("USD valuation exceeded") })
    XCTAssertNoThrow(try JSONEncoder.addressAtlas.encode(result))
  }

  func testSPLParserRejectsExponentAmountsBeforeAggregation() async throws {
    let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let http = ScannerHTTPStub { request in
      let bodyText = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      let body = try scannerJSONObject(request.httpBody ?? Data())
      if body["method"] as? String == "getBalance" {
        return scannerResponse(
          request,
          #"{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":123},"value":0}}"#
        )
      }
      let requestedProgram =
        bodyText.contains("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
        ? "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
        : "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
      let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 2,
        "result": [
          "context": ["slot": 123],
          "value": [
            [
              "pubkey": bodyText.contains("TokenzQdBN")
                ? "11111111111111111111111111111111"
                : "So11111111111111111111111111111111111111112",
              "account": [
                "owner": requestedProgram,
                "data": [
                  "parsed": [
                    "type": "account",
                    "info": [
                      "owner": "11111111111111111111111111111111",
                      "mint": usdcMint,
                      "tokenAmount": ["amount": "1e308", "decimals": 0],
                    ],
                  ]
                ],
              ],
            ]
          ],
        ],
      ]
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: "11111111111111111111111111111111")

    XCTAssertFalse(result.holdings.contains { $0.symbol == "USDC" })
    XCTAssertTrue(
      result.warnings.contains { $0.contains("invalid parsed data") },
      "Expected invalid SPL data warning, got: \(result.warnings)"
    )
    XCTAssertTrue(result.totalUsd.isFinite)
  }

  func testPersistedStargazeRecordsDecodeAndWarnWithoutBlockingSupportedWallets() async throws {
    let stargazeAddress = "stars1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqspal9j"
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    let document = VaultDocument(
      schemaVersion: 1,
      wallets: [
        WalletRecord(label: "Legacy Stargaze", address: stargazeAddress, chainKind: .cosmos),
        WalletRecord(label: "Bitcoin", address: bitcoinAddress, chainKind: .bitcoin),
      ],
      customTokens: [
        CustomTokenRecord(
          chainKind: .cosmos,
          chainId: "stargaze",
          address: stargazeAddress,
          symbol: "STARS",
          name: "Legacy Stargaze record",
          decimals: 6
        )
      ]
    )
    let decoded = try JSONDecoder.addressAtlas.decode(
      VaultDocument.self,
      from: JSONEncoder.addressAtlas.encode(document)
    )
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(
        request,
        #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["bitcoin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(
      addresses: decoded.wallets.map(\.address).joined(separator: "\n"),
      customTokens: decoded.customTokens
    )

    XCTAssertEqual(decoded.schemaVersion, VaultDocument.currentSchemaVersion)
    XCTAssertEqual(decoded.wallets.count, 2)
    XCTAssertEqual(decoded.customTokens.map(\.chainId), ["stargaze"])
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.amount, 1)
    XCTAssertEqual(requests.snapshot().count, 1)
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("Stargaze is retired") && $0.contains("saved address was kept but not scanned")
      }))
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("references retired Stargaze")
          && $0.contains("saved record was kept but not scanned")
      }))
  }

  func testRateLimitedErc20BatchDoesNotFanOutIntoIndividualCalls() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("\"eth_blockNumber\"") {
        return scannerResponse(
          request, #"{"jsonrpc":"2.0","id":1,"result":"0x10"}"#)
      }
      if body.contains("\"eth_getBalance\"") {
        return scannerResponse(
          request, #"{"jsonrpc":"2.0","id":2,"result":"0x0"}"#)
      }
      if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        return scannerResponse(
          request,
          #"{"error":"rate limited"}"#,
          statusCode: 429,
          headerFields: ["Retry-After": "0"]
        )
      }
      XCTFail("Unexpected individual ERC-20 request after a rate-limited batch: \(body)")
      return scannerResponse(request, #"{"result":"0x0"}"#)
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http, maxRateLimitRetries: 0),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "0x0000000000000000000000000000000000000001")
    let bodies = requests.snapshot().compactMap { request in
      request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    XCTAssertTrue(
      bodies.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }))
    XCTAssertFalse(
      bodies.contains(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
          && $0.contains("\"eth_call\"")
      }))
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("rate-limited") && $0.contains("individual retries")
      }))
  }

  func testPersistentTransientErc20BatchDoesNotFanOutAfterBoundedRetry() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("\"eth_blockNumber\"") {
        return scannerResponse(request, #"{"jsonrpc":"2.0","id":1,"result":"0x10"}"#)
      }
      if body.contains("\"eth_getBalance\"") {
        return scannerResponse(request, #"{"jsonrpc":"2.0","id":2,"result":"0x0"}"#)
      }
      if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        return scannerResponse(
          request,
          #"{"error":"temporarily unavailable"}"#,
          statusCode: 503,
          headerFields: ["Retry-After": "0"]
        )
      }
      XCTFail("Unexpected individual ERC-20 request after persistent batch failure: \(body)")
      return scannerResponse(request, #"{"jsonrpc":"2.0","id":1,"result":"0x0"}"#)
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(
      addresses: "0x0000000000000000000000000000000000000001")
    let bodies = requests.snapshot().compactMap { request in
      request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    let batchRequests = requests.snapshot().filter { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      return body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
    }
    XCTAssertFalse(batchRequests.isEmpty)
    XCTAssertTrue(
      Dictionary(grouping: batchRequests, by: { $0.url?.absoluteString ?? "" })
        .values.allSatisfy { $0.count == 2 }
    )
    XCTAssertFalse(
      bodies.contains(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
          && $0.contains("\"eth_call\"")
      }))
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("after one retry") && $0.contains("individual requests were skipped")
      }))
  }

  func testMalformedSolanaTokenAmountProducesVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        return scannerResponse(
          request,
          #"{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":123},"value":-1}}"#
        )
      }
      if body.contains("getSlot") {
        return scannerResponse(
          request,
          #"{"jsonrpc":"2.0","id":3,"result":123}"#
        )
      }
      let requestedProgram =
        body.contains("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
        ? "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
        : "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
      return scannerResponse(
        request,
        """
        {"jsonrpc":"2.0","id":2,"result":{"context":{"slot":123},"value":[{"pubkey":"So11111111111111111111111111111111111111112","account":{"owner":"\(requestedProgram)","data":{"parsed":{"type":"account","info":{"owner":"11111111111111111111111111111111","mint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","tokenAmount":{"amount":"not-a-number","decimals":6}}}}}}]}}
        """
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "11111111111111111111111111111111")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "USDC" }))
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("Native SOL") && $0.contains("invalid") }))
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("USDC") && $0.contains("invalid") }))
  }

  func testNegativeBitcoinProviderStatisticsProduceVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":-1,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "BTC" }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("invalid statistics") }))
  }

  func testBitcoinRejectsBalanceForDifferentEchoedAddress() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"address":"3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy","chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "BTC" }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("different address") }))
  }

  func testMalformedCosmosAmountProducesVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"not-a-number"}]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        return scannerResponse(
          request,
          #"{"delegation_responses":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      default:
        return scannerResponse(
          request,
          #"{"total":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(
      addresses: "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    )

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "ATOM" }))
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("Liquid balance could not be read") }))
  }

  func testCosmosPaginationFollowsNextKeysAndCombinesAllPages() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let nextKey = query.first(where: { $0.name == "pagination.key" })?.value
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        if nextKey == nil {
          return scannerResponse(
            request,
            #"{"balances":[{"denom":"uother","amount":"9"}],"pagination":{"next_key":"bank+/="}}"#,
            headerFields: ["x-cosmos-block-height": "123"]
          )
        }
        XCTAssertEqual(nextKey, "bank+/=")
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1200000"}],"pagination":{"next_key":null}}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        if nextKey == nil {
          return scannerResponse(
            request,
            #"{"delegation_responses":[{"delegation":{"delegator_address":"cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22","validator_address":"cosmosvaloper1first"},"balance":{"denom":"uatom","amount":"1000000"}}],"pagination":{"next_key":"stake-key"}}"#,
            headerFields: ["x-cosmos-block-height": "123"]
          )
        }
        XCTAssertEqual(nextKey, "stake-key")
        return scannerResponse(
          request,
          #"{"delegation_responses":[{"delegation":{"delegator_address":"cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22","validator_address":"cosmosvaloper1second"},"balance":{"denom":"uatom","amount":"1500000"}}],"pagination":{"next_key":""}}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      default:
        return scannerResponse(
          request,
          #"{"total":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(
      addresses: "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    )

    XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1.2)
    XCTAssertEqual(result.holdings.first(where: { $0.source == .staked })?.amount, 2.5)
    let paginated = requests.snapshot().filter {
      $0.url?.path.contains("/cosmos/bank/") == true
        || $0.url?.path.contains("/cosmos/staking/") == true
    }
    XCTAssertEqual(paginated.count, 4)
    XCTAssertTrue(
      paginated.allSatisfy { request in
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
          .contains(where: { $0.name == "pagination.limit" && $0.value == "500" }) == true
      })
    let encodedQueries = paginated.compactMap {
      URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }
    XCTAssertTrue(
      encodedQueries.contains(where: {
        $0.contains("pagination.key=bank%2B%2F%3D")
      }))
    XCTAssertFalse(encodedQueries.contains(where: { $0.contains("pagination.key=bank+") }))
  }

  func testCosmosPaginationStopsOnRepeatedKeysWithAWarning() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        _ = requests.append(request)
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1000000"}],"pagination":{"next_key":"repeat"}}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        return scannerResponse(
          request,
          #"{"delegation_responses":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      default:
        return scannerResponse(
          request,
          #"{"total":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      maxCosmosPages: 5
    )

    let result = try await scanner.scan(
      addresses: "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    )

    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("repeated key") }))
  }

  func testCosmosRequiresAndPinsOneResponseHeightAcrossParts() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        XCTAssertNil(request.value(forHTTPHeaderField: "x-cosmos-block-height"))
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1000000"}]}"#,
          headerFields: ["x-cosmos-block-height": "700"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cosmos-block-height"), "700")
        return scannerResponse(
          request,
          """
          {"delegation_responses":[{"delegation":{"delegator_address":"\(address)","validator_address":"cosmosvaloper1first"},"balance":{"denom":"uatom","amount":"2000000"}}]}
          """,
          headerFields: ["x-cosmos-block-height": "701"]
        )
      default:
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cosmos-block-height"), "700")
        return scannerResponse(
          request,
          #"{"total":[]}"#,
          headerFields: ["x-cosmos-block-height": "700"]
        )
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1)
    XCTAssertFalse(result.holdings.contains(where: { $0.source == .staked }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Delegations could not be read") }))
    XCTAssertEqual(requests.snapshot().count, 3)
  }

  func testCosmosRejectsProvidersThatDoNotEchoBoundHeight() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let pinnedHeight = request.value(forHTTPHeaderField: "x-cosmos-block-height")
      switch request.url?.path {
      case "/cosmos/base/tendermint/v1beta1/blocks/latest":
        XCTAssertNil(pinnedHeight)
        return scannerResponse(
          request,
          #"{"block":{"header":{"chain_id":"cosmoshub-4","height":"700"}}}"#
        )
      case let path? where path.contains("/cosmos/bank/"):
        if pinnedHeight == nil {
          // This unbound discovery response is deliberately discarded because
          // the provider did not echo a height.
          return scannerResponse(
            request, #"{"balances":[{"denom":"uatom","amount":"9000000"}]}"#)
        }
        XCTAssertEqual(pinnedHeight, "700")
        return scannerResponse(
          request, #"{"balances":[{"denom":"uatom","amount":"1000000"}]}"#)
      case let path? where path.contains("/cosmos/staking/"):
        XCTAssertEqual(pinnedHeight, "700")
        return scannerResponse(request, #"{"delegation_responses":[]}"#)
      default:
        XCTAssertEqual(pinnedHeight, "700")
        return scannerResponse(request, #"{"total":[]}"#)
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(requests.snapshot().count, 3)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("height-bound Cosmos snapshot") }))
  }

  func testCosmosAcceptsGrpcMetadataHeightAndPinsEveryFallbackPart() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let pinnedHeight = request.value(forHTTPHeaderField: "x-cosmos-block-height")
      switch request.url?.path {
      case "/cosmos/base/tendermint/v1beta1/blocks/latest":
        XCTAssertNil(pinnedHeight)
        return scannerResponse(
          request,
          #"{"block":{"header":{"chain_id":"cosmoshub-4","height":"700"}}}"#
        )
      case let path? where path.contains("/cosmos/bank/"):
        if pinnedHeight == nil {
          return scannerResponse(
            request, #"{"balances":[{"denom":"uatom","amount":"9000000"}]}"#)
        }
        XCTAssertEqual(pinnedHeight, "700")
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1000000"}]}"#,
          headerFields: ["grpc-metadata-x-cosmos-block-height": "700"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        XCTAssertEqual(pinnedHeight, "700")
        return scannerResponse(
          request,
          #"{"delegation_responses":[]}"#,
          headerFields: ["grpc-metadata-x-cosmos-block-height": "700"]
        )
      default:
        XCTAssertEqual(pinnedHeight, "700")
        return scannerResponse(
          request,
          #"{"total":[]}"#,
          headerFields: ["grpc-metadata-x-cosmos-block-height": "700"]
        )
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1)
    XCTAssertEqual(requests.snapshot().count, 5)
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("height-bound Cosmos snapshot") }))
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("could not be read") }))
  }

  func testCosmosSkipsBoundPartsThatOmitBothHeightHeaders() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let http = ScannerHTTPStub { request in
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1000000"}]}"#,
          headerFields: ["x-cosmos-block-height": "700"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        return scannerResponse(request, #"{"delegation_responses":[]}"#)
      default:
        return scannerResponse(request, #"{"total":[]}"#)
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1)
    XCTAssertFalse(result.holdings.contains(where: { $0.source == .staked }))
    XCTAssertFalse(result.holdings.contains(where: { $0.source == .rewards }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Delegations could not be read") }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Rewards could not be read") }))
  }

  func testCosmosRejectsLatestBlockFromTheWrongNetwork() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/cosmos/base/tendermint/v1beta1/blocks/latest" {
        return scannerResponse(
          request,
          #"{"block":{"header":{"chain_id":"osmosis-1","height":"700"}}}"#
        )
      }
      return scannerResponse(request, #"{"balances":[]}"#)
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("height-bound Cosmos snapshot") }))
  }

  func testCosmosDelegationPaginationDeduplicatesAndRejectsConflicts() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let http = ScannerHTTPStub { request in
      let nextKey = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pagination.key" })?.value
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        return scannerResponse(
          request,
          #"{"balances":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      case let path? where path.contains("/cosmos/staking/"):
        if nextKey == nil {
          return scannerResponse(
            request,
            """
            {"delegation_responses":[
              {"delegation":{"delegator_address":"\(address)","validator_address":"validator-a"},"balance":{"denom":"uatom","amount":"1000000"}},
              {"delegation":{"delegator_address":"\(address)","validator_address":"validator-b"},"balance":{"denom":"uatom","amount":"2000000"}}
            ],"pagination":{"next_key":"next"}}
            """,
            headerFields: ["x-cosmos-block-height": "123"]
          )
        }
        return scannerResponse(
          request,
          """
          {"delegation_responses":[
            {"delegation":{"delegator_address":"\(address)","validator_address":"validator-a"},"balance":{"denom":"uatom","amount":"1000000"}},
            {"delegation":{"delegator_address":"\(address)","validator_address":"validator-b"},"balance":{"denom":"uatom","amount":"3000000"}},
            {"delegation":{"delegator_address":"cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu","validator_address":"validator-c"},"balance":{"denom":"uatom","amount":"9000000"}}
          ]}
          """,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      default:
        return scannerResponse(
          request,
          #"{"total":[]}"#,
          headerFields: ["x-cosmos-block-height": "123"]
        )
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first(where: { $0.source == .staked })?.amount, 1)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("identical delegation") }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("conflicting delegation") }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("validator identity") }))
  }

  func testCosmosRewardRecordsDeduplicateOrQuarantineByDenomination() async throws {
    let address = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    let scenarios: [(total: String, expectedAmount: Double?, expectedWarning: String)] = [
      (
        """
        [{"denom":"uatom","amount":"1000000"},{"denom":"uatom","amount":"1000000"}]
        """,
        1,
        "Cosmos repeated one identical reward-balance record; the duplicate was skipped."
      ),
      (
        """
        [{"denom":"uatom","amount":"1000000"},{"denom":"uatom","amount":"2000000"}]
        """,
        nil,
        "Cosmos returned conflicting reward-balance records for 1 denomination(s); every conflicting version was skipped."
      ),
    ]

    for scenario in scenarios {
      let http = ScannerHTTPStub { request in
        switch request.url?.path {
        case let path? where path.contains("/cosmos/bank/"):
          return scannerResponse(
            request,
            #"{"balances":[]}"#,
            headerFields: ["x-cosmos-block-height": "123"]
          )
        case let path? where path.contains("/cosmos/staking/"):
          return scannerResponse(
            request,
            #"{"delegation_responses":[]}"#,
            headerFields: ["x-cosmos-block-height": "123"]
          )
        default:
          return scannerResponse(
            request,
            """
            {"total":\(scenario.total)}
            """,
            headerFields: ["x-cosmos-block-height": "123"]
          )
        }
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: ScannerStaticPriceProvider(values: [:])
      )

      let result = try await scanner.scan(addresses: address)
      let rewardAmount = result.holdings.first(where: { $0.source == .rewards })?.amount

      XCTAssertEqual(rewardAmount, scenario.expectedAmount)
      XCTAssertTrue(
        result.warnings.contains(where: { $0.contains(scenario.expectedWarning) }),
        "Expected \(scenario.expectedWarning), got \(result.warnings)"
      )
      XCTAssertEqual(result.warnings.filter { $0.contains("reward-balance record") }.count, 1)
      XCTAssertFalse(
        result.warnings.contains(where: { $0.contains(CosmosScanPart.rewards.failureWarning) }))
    }
  }

  func testTronContractRowsDeduplicateOrQuarantineByContractAddress() async throws {
    let address = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let contract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    let scenarios: [(rows: String, expectedAmount: Double?, expectedWarning: String)] = [
      (
        """
        [{"\(contract)":"1250000"},{"\(contract)":"1250000"}]
        """,
        1.25,
        "TRON repeated one identical TRC-20 contract balance record; the duplicate was skipped to avoid double-counting."
      ),
      (
        """
        [{"\(contract)":"1250000"},{"\(contract)":"2500000"}]
        """,
        nil,
        "TRON returned conflicting TRC-20 balance records for USDT; every conflicting version was skipped."
      ),
    ]

    for scenario in scenarios {
      let http = ScannerHTTPStub { request in
        scannerResponse(
          request,
          """
          {"success":true,"data":[{"address":"4174472e7d35395a6b5add427eecb7f4b62ad2b071","balance":0,"trc20":\(scenario.rows)}]}
          """
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: ScannerStaticPriceProvider(values: [:])
      )

      let result = try await scanner.scan(addresses: address)
      let tokenAmount = result.holdings.first(where: { $0.symbol == "USDT" })?.amount

      XCTAssertEqual(tokenAmount, scenario.expectedAmount)
      XCTAssertTrue(
        result.warnings.contains(where: { $0.contains(scenario.expectedWarning) }),
        "Expected \(scenario.expectedWarning), got \(result.warnings)"
      )
      XCTAssertEqual(result.warnings.filter { $0.contains("TRC-20") }.count, 1)
    }
  }

  func testMalformedTronTokenAmountProducesVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"success":true,"data":[{"address":"4174472e7d35395a6b5add427eecb7f4b62ad2b071","balance":-1,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"not-a-number"}]}]}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "USDT" }))
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("Native TRX") && $0.contains("invalid") }))
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("USDT") && $0.contains("invalid") }))
  }

  func testTronScanPublishesFragmentBasedExplorerURL() async throws {
    let address = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"success":true,"data":[{"address":"4174472e7d35395a6b5add427eecb7f4b62ad2b071","balance":1000000,"trc20":[]}]}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["tron": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(
      result.holdings.first(where: { $0.symbol == "TRX" })?.explorerUrl,
      "https://tronscan.org/#/address/\(address)"
    )
  }

  func testTronRejectsFailureWrongAccountAndMultipleRows() async throws {
    let requestedAddress = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let scenarios: [(json: String, expectedWarning: String)] = [
      (#"{"success":false,"data":[]}"#, "did not report success"),
      (
        #"{"success":true,"data":[{"address":"410000000000000000000000000000000000000000","balance":1000000}]}"#,
        "different account"
      ),
      (
        #"{"success":true,"data":[{"address":"4174472e7d35395a6b5add427eecb7f4b62ad2b071","balance":1000000},{"address":"4174472e7d35395a6b5add427eecb7f4b62ad2b071","balance":1000000}]}"#,
        "multiple account records"
      ),
    ]

    for scenario in scenarios {
      let http = ScannerHTTPStub { request in scannerResponse(request, scenario.json) }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: ScannerStaticPriceProvider(values: [:])
      )

      let result = try await scanner.scan(addresses: requestedAddress)

      XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "TRX" }))
      XCTAssertTrue(
        result.warnings.contains(where: { $0.contains(scenario.expectedWarning) }),
        "Expected \(scenario.expectedWarning), got \(result.warnings)"
      )
    }
  }

  func testPriceOutagePreservesSuccessfulNativeBalance() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":150000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerFailingPriceProvider()
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")

    XCTAssertEqual(result.holdings.first?.symbol, "BTC")
    XCTAssertEqual(result.holdings.first?.amount, 1.5)
    XCTAssertEqual(result.holdings.first?.priceUsd, 0)
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("pricing is temporarily unavailable") }))
  }

  func testXrpAccountInfoAndTrustLinePaginationStayPinnedToOneValidatedLedger() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let ledgerHash = String(repeating: "A", count: 64)
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      let method = body["method"] as? String
      if method == "account_info" {
        return scannerResponse(
          request,
          """
          {"result":{"status":"success","validated":true,"ledger_hash":"\(ledgerHash)","ledger_index":123,"account_data":{"Account":"\(address)","Balance":"1000000"}}}
          """
        )
      }
      let page = requests.append(request)
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
    let issued = result.holdings.filter { $0.source == .issued }
    let requestBodies = try requests.snapshot().map {
      try scannerJSONObject($0.httpBody ?? Data())
    }

    XCTAssertEqual(Set(issued.map(\.symbol)), ["USD", "EUR"])
    XCTAssertEqual(requests.snapshot().count, 2)
    for body in requestBodies {
      let params = (body["params"] as? [[String: Any]])?.first
      XCTAssertEqual(params?["ledger_hash"] as? String, ledgerHash)
      XCTAssertNil(params?["ledger_index"])
    }
    let secondParams = (requestBodies[1]["params"] as? [[String: Any]])?.first
    XCTAssertNotNil(secondParams?["marker"] as? [String: Any])
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("trustline") }))
  }

  func testMultiWalletWarningsUseDistinctShortHintsWithoutFullAddresses() async throws {
    let first = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let second = "rDsbeomae4FXwgQTJp9Rs64Qg9vDiTCdBv"
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      XCTAssertEqual(body["method"] as? String, "account_info")
      return scannerResponse(
        request,
        #"{"result":{"status":"error","error":"temporarilyUnavailable","error_message":"ledger lookup unavailable"}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: "\(first) \(second)")
    let warningText = result.warnings.joined(separator: "\n")

    XCTAssertTrue(warningText.contains("rG1QQv...3jCn"), warningText)
    XCTAssertTrue(warningText.contains("rDsbeo...CdBv"), warningText)
    XCTAssertFalse(warningText.contains(first))
    XCTAssertFalse(warningText.contains(second))
  }

  func testNativeGlobalDeadlineKeepsCompletedChainsAndSkipsRemainder() async throws {
    let http = ScannerHTTPStub { request in
      if request.url?.path.contains("/address/") == true {
        return scannerResponse(
          request,
          #"{"address":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT","chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
        )
      }
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return scannerResponse(request, "{}")
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [
        "bitcoin": PricePoint(usd: 100_000),
        "ripple": PricePoint(usd: 1),
      ]),
      maxConcurrentChainScans: 1,
      chainDeadline: 10,
      workflowDeadline: 0.05
    )

    let result = try await scanner.scan(
      addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    )

    XCTAssertEqual(result.holdings.map(\.symbol), ["BTC"])
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("overall scan") && $0.contains("completed results")
      }))
  }

  func testNativeScannerWarnsWhenMoreThanTwentyFourInputsAreSupplied() async throws {
    let input = (1...25)
      .map { String(format: "0x%040llx", UInt64($0)) }
      .joined(separator: " ")
    let http = ScannerHTTPStub { request in
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return scannerResponse(request, "{}")
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      maxConcurrentChainScans: 1,
      chainDeadline: 10,
      workflowDeadline: 0.03
    )

    let result = try await scanner.scan(addresses: input)

    XCTAssertEqual(result.inputCount, 24)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("first 24") }))
  }

  func testExchangeGlobalDeadlineKeepsCompletedConnectionAndAllRecords() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if request.url?.path == "/sapi/v1/account/apiRestrictions", call == 1 {
        return scannerResponse(
          request,
          #"{"enableReading":true,"enableWithdrawals":false,"enableSpotAndMarginTrading":false}"#
        )
      }
      if request.url?.path == "/api/v3/account" {
        return scannerResponse(
          request,
          #"{"balances":[{"asset":"USDC","free":"1","locked":"0"}]}"#
        )
      }
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return scannerResponse(request, "{}")
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    let connections = try (0..<2).map { index -> ExchangeConnectionRecord in
      let id = UUID()
      let envelope = try credentialVault.seal(
        ExchangeCredentials(apiKey: "key-\(index)", secret: "secret"),
        vaultKey: vaultKey,
        connectionId: id
      )
      return ExchangeConnectionRecord(
        id: id,
        provider: .binance,
        label: "Binance \(index)",
        encryptedCredentials: envelope
      )
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      maxConcurrentConnections: 1,
      connectionDeadline: 10,
      workflowDeadline: 0.05
    )

    let result = try await scanner.scanThrowing(connections: connections, vaultKey: vaultKey)

    XCTAssertEqual(result.holdings.map(\.symbol), ["USDC"])
    XCTAssertEqual(result.connections.count, 2)
    XCTAssertEqual(result.connections[0].status, .ok)
    XCTAssertEqual(result.connections[0].credentialScopeAssurance, .verifiedReadOnly)
    XCTAssertEqual(result.connections[1].status, .empty)
    XCTAssertNil(result.connections[1].credentialScopeAssurance)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("overall exchange scan") }))
  }

  func testBoundedMapPreservesOrderAndConcurrencyLimit() async throws {
    let probe = ScannerConcurrencyProbe()
    let values = try await boundedConcurrentMap(Array(0..<8), maxConcurrent: 2) { value in
      await probe.enter()
      try await Task.sleep(nanoseconds: 20_000_000)
      await probe.leave()
      return value * 2
    }

    XCTAssertEqual(values, Array(0..<8).map { $0 * 2 })
    let maximum = await probe.maximum()
    XCTAssertEqual(maximum, 2)
  }

  func testWorkflowDeadlineAndCancellationPropagate() async throws {
    do {
      _ = try await withWorkflowTimeout(seconds: .greatestFiniteMagnitude) { 1 }
      XCTFail("An unrepresentable timeout must fail without trapping.")
    } catch let error as WorkflowTimeoutError {
      XCTAssertEqual(error.seconds, .greatestFiniteMagnitude)
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    let hugeDeadlineScanner = NativeScanner(
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      workflowDeadline: .greatestFiniteMagnitude
    )
    let hugeDeadlineResult = try await hugeDeadlineScanner.scan(
      addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    )
    XCTAssertTrue(hugeDeadlineResult.warnings.contains { $0.contains("overall scan reached") })

    do {
      _ = try await withWorkflowTimeout(seconds: 0.02) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 1
      }
      XCTFail("Expected deadline.")
    } catch let error as WorkflowTimeoutError {
      XCTAssertEqual(error.seconds, 0.02)
    }

    let scanner = NativeScanner(priceProvider: ScannerSleepingPriceProvider())
    let task = Task {
      try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation.")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testCoinGeckoBatchesRequestsAndKeepsSuccessfulBatches() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 2 { return scannerResponse(request, #"{"error":"temporary"}"#, statusCode: 503) }
      let ids =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "ids" })?.value?.split(separator: ",").map(
          String.init) ?? []
      let object = Dictionary(uniqueKeysWithValues: ids.map { ($0, ["usd": 1.0]) })
      let data = try JSONSerialization.data(withJSONObject: object)
      return (data, scannerHTTPResponse(request))
    }
    let client = CoinGeckoPriceClient(http: JSONHTTPClient(http: http))

    let prices = try await client.prices(for: (0..<205).map { "coin-\($0)" })

    XCTAssertEqual(requests.snapshot().count, 4)
    XCTAssertEqual(prices.count, 205)
  }

  func testScannerRequestsHitExpectedProductionEndpointsForEveryChain() async throws {
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    let evmAddress = "0x0000000000000000000000000000000000000001"
    let solanaAddress = "11111111111111111111111111111111"
    let tronAddress = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let xrpAddress = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let cosmosAddress = "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu"
    let osmosisAddress = "osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5helwsw"
    let celestiaAddress = "celestia1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5wgawu3"
    let strideAddress = "stride1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5ufvzjs"

    // Chain id -> expected production origin and path of that chain's first
    // balance request. Pinned as literals so a drifted host or path in
    // ChainRegistry (or the bundled endpoint config that overrides it) fails
    // this test even though the HTTP stub happily answers any URL.
    let expectations: [String: (host: String, port: Int?, path: String)] = [
      "bitcoin": ("blockstream.info", nil, "/api/address/\(bitcoinAddress)"),
      "ethereum": ("ethereum-rpc.publicnode.com", nil, ""),
      "base": ("mainnet.base.org", nil, ""),
      "arbitrum": ("arb1.arbitrum.io", nil, "/rpc"),
      "optimism": ("mainnet.optimism.io", nil, ""),
      "polygon": ("polygon.drpc.org", nil, ""),
      "bsc": ("bsc-dataseed.binance.org", nil, ""),
      "avalanche": ("api.avax.network", nil, "/ext/bc/C/rpc"),
      "gnosis": ("rpc.gnosischain.com", nil, ""),
      "linea": ("rpc.linea.build", nil, ""),
      "mantle": ("rpc.mantle.xyz", nil, ""),
      "scroll": ("rpc.scroll.io", nil, ""),
      "zksync-era": ("mainnet.era.zksync.io", nil, ""),
      "solana": ("api.mainnet-beta.solana.com", nil, ""),
      "tron": ("api.trongrid.io", nil, "/v1/accounts/\(tronAddress)"),
      "xrp": ("s1.ripple.com", 51234, "/"),
      "cosmoshub": (
        "cosmos-api.polkachu.com", nil, "/cosmos/bank/v1beta1/balances/\(cosmosAddress)"
      ),
      "osmosis": ("lcd.osmosis.zone", nil, "/cosmos/bank/v1beta1/balances/\(osmosisAddress)"),
      "celestia": (
        "celestia-api.polkachu.com", nil, "/cosmos/bank/v1beta1/balances/\(celestiaAddress)"
      ),
      "stride": ("stride-api.polkachu.com", nil, "/cosmos/bank/v1beta1/balances/\(strideAddress)"),
    ]
    // Every registered chain must have an expectation, so adding a chain
    // without extending this test fails loudly.
    XCTAssertEqual(Set(expectations.keys), Set(ChainRegistry.allChains.map(\.id)))

    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      requests.append(request)
      // JSON-RPC batch bodies are arrays and must decode as arrays; every
      // other response model either tolerates an empty object or fails into a
      // per-chain warning after the request has already been captured.
      if let body = request.httpBody, body.first == UInt8(ascii: "[") {
        return scannerResponse(request, "[]")
      }
      return scannerResponse(request, "{}")
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    _ = try await scanner.scan(
      addresses: [
        bitcoinAddress, evmAddress, solanaAddress, tronAddress, xrpAddress,
        cosmosAddress, osmosisAddress, celestiaAddress, strideAddress,
      ].joined(separator: "\n"))

    let captured = requests.snapshot().compactMap(\.url)
    XCTAssertFalse(captured.isEmpty)
    for chain in ChainRegistry.allChains {
      let expected = try XCTUnwrap(expectations[chain.id], chain.id)
      XCTAssertTrue(
        captured.contains { url in
          url.scheme == "https"
            && url.host == expected.host
            && url.port == expected.port
            && url.path == expected.path
        },
        "No captured request matched https://\(expected.host)\(expected.path) for \(chain.id)."
      )
    }
    let allowedHosts = Set(expectations.values.map(\.host))
    for url in captured {
      XCTAssertTrue(
        allowedHosts.contains(url.host ?? ""),
        "Unexpected request host: \(url.absoluteString)"
      )
    }
  }
}
