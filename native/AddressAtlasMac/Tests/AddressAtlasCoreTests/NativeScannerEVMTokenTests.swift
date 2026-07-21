import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

extension NativeScannerTokenTests {
  func testErc20BalanceOfDataPadsOwnerAddress() {
    let data = NativeScanner.erc20BalanceOfData("0x000000000000000000000000000000000000dEaD")

    XCTAssertEqual(data.count, 74)
    XCTAssertTrue(data.hasPrefix("0x70a08231"))
    XCTAssertTrue(data.hasSuffix("000000000000000000000000000000000000dead"))
  }

  func testHexQuantityParserAcceptsOddLengthRpcQuantities() {
    XCTAssertEqual(NativeScanner.hexQuantityToDouble("0xf", decimals: 0), 15)
    XCTAssertEqual(NativeScanner.hexQuantityToDouble("0x280de80", decimals: 6), 42)
  }

  func testHexQuantityParserRejectsMalformedOrUnprefixedValues() {
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x10x20", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("120", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x12", decimals: 37))
  }

  func testCanonicalEvmBlockTagRejectsNonQuantityAndNormalizesHexCase() {
    XCTAssertEqual(NativeScanner.canonicalEvmBlockTag("0x0"), "0x0")
    XCTAssertEqual(NativeScanner.canonicalEvmBlockTag("0xAbC"), "0xabc")
    XCTAssertNil(NativeScanner.canonicalEvmBlockTag("0x00"))
    XCTAssertNil(NativeScanner.canonicalEvmBlockTag("0x01"))
    XCTAssertNil(NativeScanner.canonicalEvmBlockTag("latest"))
    XCTAssertNil(NativeScanner.canonicalEvmBlockTag("0x10000000000000000"))
  }

  func testCustomTokenRegistryKeepsBuiltinOnDuplicate() {
    let duplicateUsdc = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      symbol: "FAKE",
      name: "Fake USDC",
      decimals: 6
    )
    let custom = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "ONE",
      name: "One",
      decimals: 18,
      priceUsd: 1
    )

    let registries = NativeScanner.tokenRegistries(customTokens: [duplicateUsdc, custom])
    let ethereum = registries.evm["ethereum"] ?? []

    XCTAssertEqual(
      ethereum.filter { $0.address.lowercased() == duplicateUsdc.address.lowercased() }.count, 1)
    XCTAssertTrue(ethereum.contains { $0.symbol == "USDC" })
    XCTAssertTrue(ethereum.contains { $0.symbol == "ONE" })
  }

  func testEvmTokenBalancesUseJsonRpcBatchAndWarnOnPartialErrors() async throws {
    let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    let recorder = BatchRequestRecorder()
    let http = StubHTTPClient { request in
      let bodyData = request.httpBody ?? Data()
      let bodyText = String(data: bodyData, encoding: .utf8) ?? ""

      if bodyText.contains("\"eth_blockNumber\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0xabc"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if bodyText.contains("\"eth_getBalance\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":2,"result":"0x0"}"#.utf8),
          httpResponse(for: request)
        )
      }

      if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        let payload = try JSONSerialization.jsonObject(with: bodyData) as? [[String: Any]] ?? []
        recorder.append(payload.count)
        let responses: [[String: Any]] = payload.map { item in
          let id = item["id"] as? Int ?? 0
          let params = item["params"] as? [Any] ?? []
          let call = params.first as? [String: Any] ?? [:]
          let tokenAddress = (call["to"] as? String ?? "").lowercased()

          if tokenAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" {
            return ["jsonrpc": "2.0", "id": id, "result": "0x" + String(42_000_000, radix: 16)]
          }
          if tokenAddress == "0xd533a949740bb3306d119cc777fa900ba034cd52" {
            return ["jsonrpc": "2.0", "id": id, "error": ["message": "token-rpc-down"]]
          }
          return ["jsonrpc": "2.0", "id": id, "result": "0x0"]
        }
        return (try JSONSerialization.data(withJSONObject: responses), httpResponse(for: request))
      }

      XCTFail("Unexpected EVM scanner request: \(bodyText)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)
    let usdc = result.holdings.first { $0.chainId == "ethereum" && $0.symbol == "USDC" }

    XCTAssertTrue(recorder.snapshot().contains { $0 > 1 })
    XCTAssertEqual(usdc?.amount, 42)
    XCTAssertEqual(usdc?.valueUsd, 42)
    XCTAssertTrue(
      result.warnings.contains { warning in
        warning.contains("Ethereum") && warning.contains("CRV")
      })
  }

  func testEvmBatchDeduplicatesIdenticalIdsAndRejectsConflictingIds() {
    let first = TokenConfig(
      symbol: "ONE",
      name: "One",
      address: "0x0000000000000000000000000000000000000001",
      decimals: 0
    )
    let second = TokenConfig(
      symbol: "TWO",
      name: "Two",
      address: "0x0000000000000000000000000000000000000002",
      decimals: 0
    )
    let scanner = NativeScanner(priceProvider: StaticPriceProvider(values: [:]))

    let result = scanner.buildErc20TokenScan(
      address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      chain: ChainRegistry.evmChains.first { $0.id == "ethereum" }!,
      tokens: [first, second],
      responses: [
        EvmTokenBatchResponse(id: 1, result: "0x64", error: nil),
        EvmTokenBatchResponse(id: 1, result: "0x64", error: nil),
        EvmTokenBatchResponse(id: 2, result: "0x1", error: nil),
        EvmTokenBatchResponse(id: 2, result: "0x2", error: nil),
      ],
      prices: [:]
    )

    XCTAssertEqual(result.assets.map(\.symbol), ["ONE"])
    XCTAssertEqual(result.assets.first?.amount, 100)
    XCTAssertEqual(
      result.warnings,
      [
        "The EVM RPC repeated one identical token response; the duplicate was skipped.",
        "The EVM RPC returned conflicting responses for one token request; every conflicting version was skipped.",
        "ERC-20 token balance checks failed for TWO; token balances may be incomplete.",
      ]
    )
  }

  func testEvmScanPinsNativeAndEveryTokenCallToOneResolvedBlock() async throws {
    let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    let chain = try XCTUnwrap(ChainRegistry.evmChains.first { $0.id == "ethereum" })
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      decimals: 6,
      coinGeckoId: "usd-coin"
    )
    let recorder = EvmRequestBodyRecorder()
    let http = StubHTTPClient { request in
      let bodyData = request.httpBody ?? Data()
      let bodyText = String(decoding: bodyData, as: UTF8.self)
      recorder.append(bodyText)
      if bodyText.contains("\"eth_blockNumber\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0x10"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if bodyText.contains("\"eth_getBalance\"") {
        let payload = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let params = payload?["params"] as? [String]
        let result = params?.last == "0x10" ? "0xde0b6b3a7640000" : "0x0"
        return (
          Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"\(result)\"}".utf8),
          httpResponse(for: request)
        )
      }
      if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        let payload = try JSONSerialization.jsonObject(with: bodyData) as? [[String: Any]] ?? []
        let responses: [[String: Any]] = payload.map { item in
          let id = item["id"] as? Int ?? 0
          let params = item["params"] as? [Any] ?? []
          // A moving `latest` head would expose 42 USDC after the native
          // balance was read. The captured snapshot block correctly reports 0.
          let result = params.last as? String == "0x10" ? "0x0" : "0x280de80"
          return ["jsonrpc": "2.0", "id": id, "result": result]
        }
        return (try JSONSerialization.data(withJSONObject: responses), httpResponse(for: request))
      }
      XCTFail("Unexpected EVM request: \(bodyText)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.scanEVM(
      address: address, chain: chain, tokens: [token], prices: [:])

    XCTAssertEqual(result.assets.first(where: { $0.symbol == "ETH" })?.amount, 1)
    XCTAssertFalse(result.assets.contains { $0.symbol == "USDC" })
    let payloads = try recorder.snapshot().map { body -> Any in
      try JSONSerialization.jsonObject(with: Data(body.utf8))
    }
    let taggedCalls = payloads.flatMap { payload -> [[String: Any]] in
      if let request = payload as? [String: Any] { return [request] }
      return payload as? [[String: Any]] ?? []
    }.filter { request in
      ["eth_getBalance", "eth_call"].contains(request["method"] as? String)
    }
    XCTAssertFalse(taggedCalls.isEmpty)
    XCTAssertTrue(
      taggedCalls.allSatisfy { request in
        (request["params"] as? [Any])?.last as? String == "0x10"
      })
  }

  func testEvmScanRejectsMismatchedBlockLookupEnvelopeBeforeBalances() async throws {
    let chain = try XCTUnwrap(ChainRegistry.evmChains.first { $0.id == "ethereum" })
    let recorder = EvmRequestBodyRecorder()
    let http = StubHTTPClient { request in
      recorder.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
      return (
        Data(#"{"jsonrpc":"2.0","id":99,"result":"0x10"}"#.utf8),
        httpResponse(for: request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http), priceProvider: StaticPriceProvider(values: [:]))

    do {
      _ = try await scanner.scanEVM(
        address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        chain: chain,
        tokens: [],
        prices: [:]
      )
      XCTFail("Expected mismatched JSON-RPC identity to fail.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("mismatched JSON-RPC"))
    }
    XCTAssertEqual(recorder.snapshot().count, 1)
  }

  func testEvmBatchTreatsSuccessAndEmptyErrorAsConflictingInEitherOrder() {
    let token = TokenConfig(
      symbol: "ONE",
      name: "One",
      address: "0x0000000000000000000000000000000000000001",
      decimals: 0
    )
    let success = EvmTokenBatchResponse(id: 1, result: "0x64", error: nil)
    let emptyError = EvmTokenBatchResponse(
      id: 1,
      result: "0x64",
      error: JSONRPCError(code: nil, message: nil)
    )
    let scanner = NativeScanner(priceProvider: StaticPriceProvider(values: [:]))

    for responses in [[success, emptyError], [emptyError, success]] {
      let result = scanner.buildErc20TokenScan(
        address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        chain: ChainRegistry.evmChains.first { $0.id == "ethereum" }!,
        tokens: [token],
        responses: responses,
        prices: [:]
      )

      XCTAssertTrue(result.assets.isEmpty)
      XCTAssertEqual(
        result.warnings,
        [
          "The EVM RPC returned conflicting responses for one token request; every conflicting version was skipped.",
          "ERC-20 token balance checks failed for ONE; token balances may be incomplete.",
        ]
      )
    }
  }

  func testEvmBatchRejectsMissingJsonRpcVersion() throws {
    let decoded = try JSONDecoder.addressAtlas.decode(
      [EvmTokenBatchResponse].self,
      from: Data(#"[{"id":1,"result":"0x64"}]"#.utf8)
    )
    let token = TokenConfig(
      symbol: "ONE",
      name: "One",
      address: "0x0000000000000000000000000000000000000001",
      decimals: 0
    )
    let scanner = NativeScanner(priceProvider: StaticPriceProvider(values: [:]))

    let result = scanner.buildErc20TokenScan(
      address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      chain: ChainRegistry.evmChains.first { $0.id == "ethereum" }!,
      tokens: [token],
      responses: decoded,
      prices: [:]
    )

    XCTAssertTrue(result.assets.isEmpty)
    XCTAssertTrue(result.warnings.contains { $0.contains("ONE") })
  }

  func testEvmIndividualFallbackReusesTheResolvedBlock() async throws {
    let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    let chain = try XCTUnwrap(ChainRegistry.evmChains.first { $0.id == "ethereum" })
    let token = TokenConfig(
      symbol: "ONE",
      name: "One",
      address: "0x0000000000000000000000000000000000000001",
      decimals: 0
    )
    let recorder = EvmRequestBodyRecorder()
    let http = StubHTTPClient { request in
      let bodyData = request.httpBody ?? Data()
      let bodyText = String(decoding: bodyData, as: UTF8.self)
      recorder.append(bodyText)
      if bodyText.contains("\"eth_blockNumber\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0x20"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if bodyText.contains("\"eth_getBalance\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":2,"result":"0x0"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        // Force the batch decoder to fail so the individual safety fallback runs.
        return (Data("{}".utf8), httpResponse(for: request))
      }
      let payload = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
      let params = payload?["params"] as? [Any]
      XCTAssertEqual(params?.last as? String, "0x20")
      return (
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x2a"}"#.utf8),
        httpResponse(for: request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http), priceProvider: StaticPriceProvider(values: [:]))

    let result = try await scanner.scanEVM(
      address: address, chain: chain, tokens: [token], prices: [:])

    XCTAssertEqual(result.assets.first(where: { $0.symbol == "ONE" })?.amount, 42)
    XCTAssertTrue(
      recorder.snapshot().contains { body in
        body.contains("\"eth_call\"")
          && !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
      })
  }

  func testEvmBatchDuplicateWarningsUsePluralGrammarForCountTwo() {
    let tokens = ["ONE", "TWO", "THREE"].enumerated().map { index, symbol in
      TokenConfig(
        symbol: symbol,
        name: symbol,
        address: String(format: "0x%040x", index + 1),
        decimals: 0
      )
    }
    let scanner = NativeScanner(priceProvider: StaticPriceProvider(values: [:]))

    let result = scanner.buildErc20TokenScan(
      address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      chain: ChainRegistry.evmChains.first { $0.id == "ethereum" }!,
      tokens: tokens,
      responses: [
        EvmTokenBatchResponse(id: 1, result: "0x1", error: nil),
        EvmTokenBatchResponse(id: 1, result: "0x1", error: nil),
        EvmTokenBatchResponse(id: 1, result: "0x1", error: nil),
        EvmTokenBatchResponse(id: 2, result: "0x2", error: nil),
        EvmTokenBatchResponse(id: 2, result: "0x3", error: nil),
        EvmTokenBatchResponse(id: 3, result: "0x4", error: nil),
        EvmTokenBatchResponse(id: 3, result: "0x5", error: nil),
      ],
      prices: [:]
    )

    XCTAssertEqual(
      Array(result.warnings.prefix(2)),
      [
        "The EVM RPC repeated 2 identical token responses; the duplicates were skipped.",
        "The EVM RPC returned conflicting responses for 2 token requests; every conflicting version was skipped.",
      ]
    )
  }

}

private final class EvmRequestBodyRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var bodies: [String] = []

  func append(_ body: String) {
    lock.lock()
    bodies.append(body)
    lock.unlock()
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return bodies
  }
}
