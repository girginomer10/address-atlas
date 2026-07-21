import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

extension NativeScannerTokenTests {
  func testConcurrentSameChainJobsCoalesceOneNetworkIdentityProof() async throws {
    let identityRequests = BatchRequestRecorder()
    let http = StubHTTPClient(automaticallyServesNetworkIdentity: false) { request in
      let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
      if body.contains("\"eth_chainId\"") {
        identityRequests.append(1)
        Thread.sleep(forTimeInterval: 0.02)
        return (
          Data(#"{"jsonrpc":"2.0","id":0,"result":"0x1"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("\"eth_blockNumber\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0xabc"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("\"eth_getBalance\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":2,"result":"0x0"}"#.utf8),
          httpResponse(for: request)
        )
      }
      XCTFail("Unexpected EVM request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )
    let workflowProofs = ChainNetworkValueCache<Void>()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          _ = try await scanner.scanEVM(
            address: String(format: "0x%040x", index + 1),
            chain: ChainRegistry.evmChains[0],
            tokens: [],
            prices: [:],
            networkIdentityProofs: workflowProofs
          )
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(identityRequests.snapshot().count, 1)
  }

  func testRemoteEndpointOnWrongEvmNetworkFailsEveryJobClosedAndCachesFailure() async {
    let identityRequests = BatchRequestRecorder()
    let http = StubHTTPClient(automaticallyServesNetworkIdentity: false) { request in
      let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
      guard body.contains("\"eth_chainId\"") else {
        XCTFail("No balance request may follow a wrong-network proof: \(body)")
        return (Data("{}".utf8), httpResponse(for: request))
      }
      identityRequests.append(1)
      return (
        Data(#"{"jsonrpc":"2.0","id":0,"result":"0x5"}"#.utf8),
        httpResponse(for: request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )
    let workflowProofs = ChainNetworkValueCache<Void>()
    var configuredWrongNetwork = ChainRegistry.evmChains[0]
    configuredWrongNetwork.rpcUrl = URL(string: "https://wrong-network.example/rpc")!
    let remotelyMovedEthereum = configuredWrongNetwork

    let failures = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for index in 0..<8 {
        group.addTask {
          do {
            _ = try await scanner.scanEVM(
              address: String(format: "0x%040x", index + 1),
              chain: remotelyMovedEthereum,
              tokens: [],
              prices: [:],
              networkIdentityProofs: workflowProofs
            )
            return false
          } catch {
            return error.localizedDescription.contains("wrong network identity")
          }
        }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }

    XCTAssertTrue(failures.allSatisfy { $0 })
    XCTAssertEqual(identityRequests.snapshot().count, 1)
    XCTAssertEqual(remotelyMovedEthereum.networkIdentity, .evmChainID(1))
  }

  func testCancellingEveryIdentityWaiterPromptlyStopsProducerAndStartsNoBalanceCalls() async {
    let probe = EvmIdentityCancellationProbe()
    let http = ScannerHTTPStub(automaticallyServesNetworkIdentity: false) { request in
      let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
      if body.contains("\"eth_chainId\"") {
        await probe.identityStarted()
        try await Task.sleep(for: .seconds(60))
        return (
          Data(#"{"jsonrpc":"2.0","id":0,"result":"0x1"}"#.utf8),
          scannerHTTPResponse(request)
        )
      }
      await probe.balanceStarted()
      return (Data("{}".utf8), scannerHTTPResponse(request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )
    let workflowProofs = ChainNetworkValueCache<Void>()
    let first = Task {
      try await scanner.scanEVM(
        address: "0x0000000000000000000000000000000000000001",
        chain: ChainRegistry.evmChains[0],
        tokens: [],
        prices: [:],
        networkIdentityProofs: workflowProofs
      )
    }
    let second = Task {
      try await scanner.scanEVM(
        address: "0x0000000000000000000000000000000000000002",
        chain: ChainRegistry.evmChains[0],
        tokens: [],
        prices: [:],
        networkIdentityProofs: workflowProofs
      )
    }
    await probe.waitUntilIdentityStarted()
    let startedAt = ContinuousClock.now
    first.cancel()
    second.cancel()

    for task in [first, second] {
      do {
        _ = try await task.value
        XCTFail("Expected every canceled shared-proof waiter to fail closed")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
    }
    XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(1))
    let balanceRequestCount = await probe.balanceRequestCount()
    XCTAssertEqual(balanceRequestCount, 0)
  }

  func testSeparateEvmScanWorkflowsReproveIdentityAndRecoverAfterTransientFailure() async throws {
    let identityRequests = BatchRequestRecorder()
    let balanceRequests = BatchRequestRecorder()
    let http = StubHTTPClient(automaticallyServesNetworkIdentity: false) { request in
      let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
      if body.contains("\"eth_chainId\"") {
        identityRequests.append(1)
        let chainID = identityRequests.snapshot().count == 1 ? "0x5" : "0x1"
        return (
          Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":\"\(chainID)\"}".utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("\"eth_blockNumber\"") {
        return (
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0xabc"}"#.utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("\"eth_getBalance\"") {
        balanceRequests.append(1)
        return (
          Data(#"{"jsonrpc":"2.0","id":2,"result":"0x0"}"#.utf8),
          httpResponse(for: request)
        )
      }
      XCTFail("Unexpected EVM request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )
    let address = "0x0000000000000000000000000000000000000001"
    let ethereum = ChainRegistry.evmChains[0]

    do {
      _ = try await scanner.scanEVM(
        address: address, chain: ethereum, tokens: [], prices: [:])
      XCTFail("Expected the first workflow's wrong-network proof to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("wrong network identity"))
    }
    _ = try await scanner.scanEVM(
      address: address, chain: ethereum, tokens: [], prices: [:])

    XCTAssertEqual(identityRequests.snapshot().count, 2)
    XCTAssertEqual(balanceRequests.snapshot().count, 1)
  }

  func testCanceledWaiterCannotReturnSuccessWhenProducerFinishWinsActorRace() async {
    for iteration in 0..<50 {
      let cache = ChainNetworkValueCache<Int>()
      let gate = IdentityFinishRaceGate()
      let waiter = Task {
        try await cache.value(
          chainID: "ethereum",
          endpoint: URL(string: "https://rpc.example/\(iteration)")!,
          identity: .evmChainID(1)
        ) {
          await gate.waitForRelease()
          return iteration
        }
      }
      await gate.waitUntilStarted()
      // Cancellation is immediate, but the cache's onCancel cleanup is actor
      // work. Releasing now deliberately lets producer finish race that cleanup.
      waiter.cancel()
      await gate.release()
      do {
        _ = try await waiter.value
        XCTFail("A canceled identity waiter must never observe producer success")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
    }
  }

  func testCancelingOneSharedIdentityWaiterDoesNotCancelItsSibling() async throws {
    let cache = ChainNetworkValueCache<Int>()
    let gate = IdentityFinishRaceGate()
    let endpoint = URL(string: "https://rpc.example/shared-cancellation")!
    let producerCalls = BatchRequestRecorder()

    let canceled = Task {
      try await cache.value(
        chainID: "ethereum",
        endpoint: endpoint,
        identity: .evmChainID(1)
      ) {
        producerCalls.append(1)
        await gate.waitForRelease()
        return 42
      }
    }
    await gate.waitUntilStarted()

    let sibling = Task {
      try await cache.value(
        chainID: "ethereum",
        endpoint: endpoint,
        identity: .evmChainID(1)
      ) {
        producerCalls.append(1)
        return -1
      }
    }
    // Give the sibling's actor hop a chance to register behind the producer.
    await Task.yield()
    await Task.yield()
    canceled.cancel()
    await gate.release()

    do {
      _ = try await canceled.value
      XCTFail("The canceled waiter must not observe shared producer success")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let siblingValue = try await sibling.value
    XCTAssertEqual(siblingValue, 42)
    XCTAssertEqual(producerCalls.snapshot().count, 1)
  }

  func testCanceledProducerCannotCompleteReplacementGenerationForSameKey() async throws {
    let cache = ChainNetworkValueCache<Int>()
    let endpoint = URL(string: "https://rpc.example/replacement-generation")!
    let canceledGenerationGate = IdentityFinishRaceGate()
    let replacementGenerationGate = IdentityFinishRaceGate()

    let canceledGeneration = Task {
      try await cache.value(
        chainID: "ethereum",
        endpoint: endpoint,
        identity: .evmChainID(1)
      ) {
        // This deliberately ignores task cancellation so the detached producer
        // can finish after its last waiter has already removed the old entry.
        await canceledGenerationGate.waitForRelease()
        return 111
      }
    }
    await canceledGenerationGate.waitUntilStarted()
    canceledGeneration.cancel()
    do {
      _ = try await canceledGeneration.value
      XCTFail("The canceled generation's waiter must fail")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }

    let replacementGeneration = Task {
      try await cache.value(
        chainID: "ethereum",
        endpoint: endpoint,
        identity: .evmChainID(1)
      ) {
        await replacementGenerationGate.waitForRelease()
        return 222
      }
    }
    await replacementGenerationGate.waitUntilStarted()

    // Let the canceled producer finish while the replacement entry is live.
    // Without a generation check, its late result consumes the new waiter.
    await canceledGenerationGate.release()
    try await Task.sleep(for: .milliseconds(50))
    await replacementGenerationGate.release()

    let replacementValue = try await replacementGeneration.value
    XCTAssertEqual(replacementValue, 222)
  }

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
        return (
          Data(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Batch requests are not supported"}}"#
              .utf8),
          httpResponse(for: request)
        )
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

  func testMalformedSuccessfulEvmBatchDoesNotAmplifyIntoIndividualCalls() async throws {
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
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      recorder.append(body)
      XCTAssertTrue(body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["))
      return (Data(#"{"truncated":true}"#.utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http), priceProvider: StaticPriceProvider(values: [:]))

    let result = try await scanner.scanErc20Balances(
      address: address,
      chain: chain,
      tokens: [token],
      prices: [:],
      blockTag: "0x20"
    )

    XCTAssertTrue(result.assets.isEmpty)
    XCTAssertEqual(recorder.snapshot().count, 1)
    XCTAssertTrue(result.warnings.contains { $0.contains("individual requests were skipped") })
  }

  func testHttpStatusEvmBatchFailuresDoNotAmplifyIntoIndividualCalls() async throws {
    let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    let chain = try XCTUnwrap(ChainRegistry.evmChains.first { $0.id == "ethereum" })
    let token = TokenConfig(
      symbol: "ONE",
      name: "One",
      address: "0x0000000000000000000000000000000000000001",
      decimals: 0
    )
    for statusCode in [400, 405, 415, 422, 501] {
      let recorder = EvmRequestBodyRecorder()
      let http = StubHTTPClient { request in
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        recorder.append(body)
        XCTAssertTrue(body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["))
        return (
          Data(#"{"error":"invalid API policy"}"#.utf8),
          httpResponse(for: request, statusCode: statusCode)
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http), priceProvider: StaticPriceProvider(values: [:]))

      let result = try await scanner.scanErc20Balances(
        address: address,
        chain: chain,
        tokens: [token],
        prices: [:],
        blockTag: "0x20"
      )

      XCTAssertTrue(result.assets.isEmpty, "status \(statusCode)")
      XCTAssertEqual(recorder.snapshot().count, statusCode == 501 ? 2 : 1)
      XCTAssertTrue(
        result.warnings.contains { $0.contains("individual requests were skipped") },
        "status \(statusCode)"
      )
    }
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

private actor EvmIdentityCancellationProbe {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var balanceCalls = 0

  func identityStarted() {
    started = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }

  func waitUntilIdentityStarted() async {
    if started { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func balanceStarted() { balanceCalls += 1 }
  func balanceRequestCount() -> Int { balanceCalls }
}

private actor IdentityFinishRaceGate {
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
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
