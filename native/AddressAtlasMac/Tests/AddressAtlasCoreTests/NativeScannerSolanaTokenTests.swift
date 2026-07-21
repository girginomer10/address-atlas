import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

private enum SolanaTokenFixture {
  static let owner = "11111111111111111111111111111111"
  static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  static let legacyProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  static let token2022Program = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
}

private func solanaTokenAccountJSON(
  publicKey: String,
  accountProgram: String,
  parsedType: String = "account",
  walletOwner: String = SolanaTokenFixture.owner,
  mint: String = SolanaTokenFixture.mint,
  rawAmount: String,
  decimals: Int
) -> [String: Any] {
  [
    "pubkey": publicKey,
    "account": [
      "owner": accountProgram,
      "data": [
        "parsed": [
          "type": parsedType,
          "info": [
            "owner": walletOwner,
            "mint": mint,
            "tokenAmount": ["amount": rawAmount, "decimals": decimals],
          ],
        ]
      ],
    ],
  ]
}

private func solanaTokenAccountsResponseData(
  _ accounts: [[String: Any]],
  jsonrpc: String = "2.0",
  id: Int = 2,
  slot: UInt64 = 123
) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: [
      "jsonrpc": jsonrpc,
      "id": id,
      "result": ["context": ["slot": slot], "value": accounts],
    ])
}

private func solanaMinimumContextSlotErrorData(id: Int = 2) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: [
      "jsonrpc": "2.0",
      "id": id,
      "error": [
        "code": -32016,
        "message": "Minimum context slot has not been reached",
      ],
    ])
}

private func requestedSolanaProgram(in request: URLRequest) -> String {
  let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  return body.contains(SolanaTokenFixture.token2022Program)
    ? SolanaTokenFixture.token2022Program
    : SolanaTokenFixture.legacyProgram
}

private func requestedSolanaMethod(in request: URLRequest) -> String? {
  guard let data = request.httpBody,
    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }
  return body["method"] as? String
}

private func requestedSolanaMinimumSlot(in request: URLRequest) -> UInt64? {
  guard let data = request.httpBody,
    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let params = body["params"] as? [Any],
    let config = params.last as? [String: Any],
    let minimumSlot = config["minContextSlot"] as? NSNumber
  else { return nil }
  return minimumSlot.uint64Value
}

private actor SolanaRequestStartProbe {
  private var requestCount = 0
  private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  func recordRequest() {
    requestCount += 1
    let satisfiedTargets = waiters.keys.filter { $0 <= requestCount }
    for target in satisfiedTargets {
      for waiter in waiters.removeValue(forKey: target) ?? [] {
        waiter.resume()
      }
    }
  }

  func waitUntilRequestCount(_ expected: Int) async {
    guard requestCount < expected else { return }
    await withCheckedContinuation { continuation in
      waiters[expected, default: []].append(continuation)
    }
  }

  func count() -> Int { requestCount }
}

extension NativeScannerTokenTests {
  func testSolanaWrongGenesisHashStopsBeforeAnyBalanceRequest() async {
    let http = StubHTTPClient(automaticallyServesNetworkIdentity: false) { request in
      XCTAssertEqual(requestedSolanaMethod(in: request), "getGenesisHash")
      return (
        Data(#"{"jsonrpc":"2.0","id":0,"result":"GH7ome3EiwEr7tu9JuTh2dpYWBJK3z69Xm1ZE3MEE6JC"}"#.utf8),
        httpResponse(for: request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    do {
      _ = try await scanner.scanSolana(
        address: SolanaTokenFixture.owner,
        chain: ChainRegistry.solana,
        tokens: [],
        prices: [:]
      )
      XCTFail("Expected wrong Solana cluster rejection")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("wrong network identity"))
    }
  }

  func testSolanaNativeBalanceAcceptsFullUInt64LamportRange() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(requestedSolanaMethod(in: request), "getBalance")
      return (
        Data(
          #"{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":123},"value":18446744073709551615}}"#
            .utf8),
        httpResponse(for: request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.scanSolana(
      address: SolanaTokenFixture.owner,
      chain: ChainRegistry.solana,
      tokens: [],
      prices: [:]
    )

    XCTAssertEqual(result.assets.count, 1)
    XCTAssertEqual(result.assets[0].symbol, "SOL")
    XCTAssertEqual(result.assets[0].amount, Double(UInt64.max) / 1_000_000_000)
    XCTAssertTrue(result.warnings.isEmpty)
  }

  func testSolanaNativeBalanceRejectsFractionalAndOutOfRangeLamports() async throws {
    for rawValue in ["1.5", "18446744073709551616"] {
      let http = StubHTTPClient { request in
        XCTAssertEqual(requestedSolanaMethod(in: request), "getBalance")
        return (
          Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"context\":{\"slot\":123},\"value\":\(rawValue)}}"
              .utf8),
          httpResponse(for: request)
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: StaticPriceProvider(values: [:])
      )

      let result = try await scanner.scanSolana(
        address: SolanaTokenFixture.owner,
        chain: ChainRegistry.solana,
        tokens: [],
        prices: [:]
      )

      XCTAssertTrue(result.assets.isEmpty, "raw value: \(rawValue)")
      XCTAssertTrue(
        result.warnings.contains {
          $0.contains("Native SOL balance could not be read") && $0.contains("invalid data")
        },
        "raw value: \(rawValue)"
      )
    }
  }

  func testSolanaRejectsWrongEnvelopeIdentityAndStaleContextSlot() async throws {
    let publicKey = "So11111111111111111111111111111111111111112"
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: SolanaTokenFixture.mint,
      decimals: 6
    )
    let invalidResponses: [(jsonrpc: String, id: Int, slot: UInt64)] = [
      ("1.0", 2, 123),
      ("2.0", 99, 123),
      ("2.0", 2, 122),
    ]

    for invalid in invalidResponses {
      let requests = ScannerRequestLog()
      let http = StubHTTPClient { request in
        _ = requests.append(request)
        let program = requestedSolanaProgram(in: request)
        let data = try solanaTokenAccountsResponseData(
          [
            solanaTokenAccountJSON(
              publicKey: publicKey,
              accountProgram: program,
              rawAmount: "1000000",
              decimals: 6
            )
          ],
          jsonrpc: invalid.jsonrpc,
          id: invalid.id,
          slot: invalid.slot
        )
        return (data, httpResponse(for: request))
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: StaticPriceProvider(values: [:])
      )

      let result = try await scanner.fetchSolanaTokenBalances(
        rpc: URL(string: "https://solana.example")!,
        owner: SolanaTokenFixture.owner,
        registry: [token],
        minimumSlot: 123
      )

      XCTAssertTrue(result.balances.isEmpty)
      XCTAssertEqual(result.warnings.count, 2)
      for request in requests.snapshot() {
        let body = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            as? [String: Any])
        let params = try XCTUnwrap(body["params"] as? [Any])
        let config = try XCTUnwrap(params.last as? [String: Any])
        XCTAssertEqual(config["minContextSlot"] as? Int, 123)
      }
    }
  }

  func testSolanaSnapshotRefetchesOnlyLaggingComponentsUntilEveryResultConverges()
    async throws
  {
    let requests = ScannerRequestLog()
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      let minimumSlot = requestedSolanaMinimumSlot(in: request)
      switch requestedSolanaMethod(in: request) {
      case "getBalance":
        let slot: UInt64 = minimumSlot == nil ? 123 : 125
        let lamports = minimumSlot == nil ? 1_000_000_000 : 2_000_000_000
        return (
          Data(
            """
            {"jsonrpc":"2.0","id":1,"result":{"context":{"slot":\(slot)},"value":\(lamports)}}
            """.utf8),
          httpResponse(for: request)
        )
      case "getTokenAccountsByOwner":
        let program = requestedSolanaProgram(in: request)
        if program == SolanaTokenFixture.token2022Program {
          return (
            try solanaTokenAccountsResponseData([], slot: 125),
            httpResponse(for: request)
          )
        }

        let isConvergenceRead = minimumSlot == 125
        let slot: UInt64 = isConvergenceRead ? 125 : 124
        let rawAmount = isConvergenceRead ? "1000000" : "999"
        return (
          try solanaTokenAccountsResponseData(
            [
              solanaTokenAccountJSON(
                publicKey: "So11111111111111111111111111111111111111112",
                accountProgram: program,
                rawAmount: rawAmount,
                decimals: 6
              )
            ],
            slot: slot
          ),
          httpResponse(for: request)
        )
      default:
        XCTFail("Unexpected Solana method: \(requestedSolanaMethod(in: request) ?? "nil")")
        return (Data("{}".utf8), httpResponse(for: request))
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(
        values: [
          "solana": PricePoint(usd: 10),
          "usd-coin": PricePoint(usd: 1),
        ])
    )

    let result = try await scanner.scan(addresses: SolanaTokenFixture.owner)

    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "SOL" })?.amount, 2)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USDC" })?.amount, 1)
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("coherent context slot") }))

    let requestSnapshot = requests.snapshot()
    XCTAssertEqual(
      requestSnapshot.filter { requestedSolanaMethod(in: $0) == "getBalance" }.count,
      2
    )
    XCTAssertEqual(
      requestSnapshot.filter { requestedSolanaMethod(in: $0) == "getTokenAccountsByOwner" }.count,
      3
    )
    XCTAssertEqual(
      requestSnapshot
        .filter {
          requestedSolanaMethod(in: $0) == "getTokenAccountsByOwner"
            && requestedSolanaProgram(in: $0) == SolanaTokenFixture.legacyProgram
        }
        .compactMap(requestedSolanaMinimumSlot)
        .sorted(),
      [123, 125]
    )
  }

  func testSolanaSnapshotNonConvergenceFailsClosedWithBoundedAmplification() async throws {
    let requests = ScannerRequestLog()
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      let minimumSlot = requestedSolanaMinimumSlot(in: request)
      switch requestedSolanaMethod(in: request) {
      case "getBalance":
        let slot = minimumSlot.map { $0 + 1 } ?? 100
        return (
          Data(
            """
            {"jsonrpc":"2.0","id":1,"result":{"context":{"slot":\(slot)},"value":1000000000}}
            """.utf8),
          httpResponse(for: request)
        )
      case "getTokenAccountsByOwner":
        let program = requestedSolanaProgram(in: request)
        let offset: UInt64 =
          program == SolanaTokenFixture.legacyProgram ? 2 : 3
        let slot = (minimumSlot ?? 100) + offset
        let accounts =
          program == SolanaTokenFixture.legacyProgram
          ? [
            solanaTokenAccountJSON(
              publicKey: "So11111111111111111111111111111111111111112",
              accountProgram: program,
              rawAmount: "1000000",
              decimals: 6
            )
          ] : []
        return (
          try solanaTokenAccountsResponseData(accounts, slot: slot),
          httpResponse(for: request)
        )
      default:
        XCTFail("Unexpected Solana method: \(requestedSolanaMethod(in: request) ?? "nil")")
        return (Data("{}".utf8), httpResponse(for: request))
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: SolanaTokenFixture.owner)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("coherent context slot") && $0.contains("3 bounded snapshot attempts")
      }))
    XCTAssertEqual(requests.snapshot().count, 7)
  }

  func testSolanaSnapshotRetriesMinimumContextSlotFailureThenConverges() async throws {
    let requests = ScannerRequestLog()
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: SolanaTokenFixture.mint,
      decimals: 6
    )
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      let program = requestedSolanaProgram(in: request)
      let programRequestCount = requests.snapshot().filter {
        requestedSolanaMethod(in: $0) == "getTokenAccountsByOwner"
          && requestedSolanaProgram(in: $0) == program
      }.count
      if program == SolanaTokenFixture.legacyProgram, programRequestCount == 1 {
        return (try solanaMinimumContextSlotErrorData(), httpResponse(for: request))
      }
      let accounts =
        program == SolanaTokenFixture.legacyProgram
        ? [
          solanaTokenAccountJSON(
            publicKey: "So11111111111111111111111111111111111111112",
            accountProgram: program,
            rawAmount: "1000000",
            decimals: 6
          )
        ] : []
      return (
        try solanaTokenAccountsResponseData(accounts, slot: 123),
        httpResponse(for: request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.fetchSolanaTokenBalances(
      rpc: URL(string: "https://solana.example")!,
      owner: SolanaTokenFixture.owner,
      registry: [token],
      minimumSlot: 123
    )

    XCTAssertEqual(result.balances.map(\.amount), [1])
    XCTAssertTrue(result.warnings.isEmpty)
    let requestSnapshot = requests.snapshot()
    XCTAssertEqual(requestSnapshot.count, 3)
    XCTAssertEqual(
      requestSnapshot.filter {
        requestedSolanaProgram(in: $0) == SolanaTokenFixture.legacyProgram
      }.count,
      2
    )
  }

  func testSolanaSnapshotBoundsRepeatedMinimumContextSlotFailures() async throws {
    let requests = ScannerRequestLog()
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: SolanaTokenFixture.mint,
      decimals: 6
    )
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      let program = requestedSolanaProgram(in: request)
      if program == SolanaTokenFixture.legacyProgram {
        return (try solanaMinimumContextSlotErrorData(), httpResponse(for: request))
      }
      return (try solanaTokenAccountsResponseData([], slot: 123), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.fetchSolanaTokenBalances(
      rpc: URL(string: "https://solana.example")!,
      owner: SolanaTokenFixture.owner,
      registry: [token],
      minimumSlot: 123
    )

    XCTAssertTrue(result.balances.isEmpty)
    XCTAssertEqual(result.warnings.count, 1)
    XCTAssertTrue(result.warnings[0].contains("SPL Token"))
    let requestSnapshot = requests.snapshot()
    XCTAssertEqual(requestSnapshot.count, 4)
    XCTAssertEqual(
      requestSnapshot.filter {
        requestedSolanaProgram(in: $0) == SolanaTokenFixture.legacyProgram
      }.count,
      3
    )
  }

  func testSolanaSnapshotPreservesCoherentNativeAndLegacyResultsWhenToken2022Fails()
    async throws
  {
    let http = StubHTTPClient { request in
      let minimumSlot = requestedSolanaMinimumSlot(in: request)
      switch requestedSolanaMethod(in: request) {
      case "getBalance":
        let slot: UInt64 = minimumSlot == nil ? 123 : 124
        return (
          Data(
            """
            {"jsonrpc":"2.0","id":1,"result":{"context":{"slot":\(slot)},"value":1000000000}}
            """.utf8),
          httpResponse(for: request)
        )
      case "getTokenAccountsByOwner":
        let program = requestedSolanaProgram(in: request)
        if program == SolanaTokenFixture.token2022Program {
          throw URLError(.badServerResponse)
        }
        return (
          try solanaTokenAccountsResponseData(
            [
              solanaTokenAccountJSON(
                publicKey: "So11111111111111111111111111111111111111112",
                accountProgram: program,
                rawAmount: "1000000",
                decimals: 6
              )
            ],
            slot: 124
          ),
          httpResponse(for: request)
        )
      default:
        XCTFail("Unexpected Solana method: \(requestedSolanaMethod(in: request) ?? "nil")")
        return (Data("{}".utf8), httpResponse(for: request))
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: SolanaTokenFixture.owner)

    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "SOL" })?.amount, 1)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USDC" })?.amount, 1)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Token-2022") }))
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("coherent context slot") }))
  }

  func testSolanaSnapshotCancellationPropagatesWithoutConvergenceRetries() async throws {
    let probe = SolanaRequestStartProbe()
    let http = ScannerHTTPStub { request in
      await probe.recordRequest()
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: SolanaTokenFixture.mint,
      decimals: 6
    )

    let operation = Task {
      try await scanner.fetchSolanaTokenBalances(
        rpc: URL(string: "https://solana.example")!,
        owner: SolanaTokenFixture.owner,
        registry: [token],
        minimumSlot: 123
      )
    }
    await probe.waitUntilRequestCount(2)
    operation.cancel()
    do {
      _ = try await operation.value
      XCTFail("Expected snapshot cancellation to propagate.")
    } catch is CancellationError {
      // Expected: cancellation is never converted into a partial-balance warning.
    }
    let requestCount = await probe.count()
    XCTAssertEqual(requestCount, 2)
  }

  func testSolanaTokenAccountParserReadsJsonParsedBalances() throws {
    let data = try solanaTokenAccountsResponseData([
      solanaTokenAccountJSON(
        publicKey: "So11111111111111111111111111111111111111112",
        accountProgram: SolanaTokenFixture.legacyProgram,
        rawAmount: "1234500",
        decimals: 6
      )
    ])
    let response = try JSONDecoder.addressAtlas.decode(
      SolanaTokenAccountsResponse.self,
      from: data
    )
    let parsed = NativeScanner.parseSolanaTokenAccounts(
      response.result?.value ?? [],
      expectedOwner: SolanaTokenFixture.owner,
      expectedProgram: SolanaTokenFixture.legacyProgram
    )

    XCTAssertEqual(
      parsed,
      [
        ParsedSplAccount(
          accountPublicKey: "So11111111111111111111111111111111111111112",
          mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
          rawAmount: 1_234_500,
          decimals: 6
        )
      ])
  }

  func testSolanaTokenAccountsDeduplicateIdenticalAndRejectConflictingPublicKeys() {
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let identical = ParsedSplAccount(
      accountPublicKey: "So11111111111111111111111111111111111111112",
      mint: mint,
      rawAmount: 10,
      decimals: 6
    )
    let conflictingKey = "11111111111111111111111111111111"
    let result = NativeScanner.deduplicateSolanaAccounts([
      identical,
      identical,
      ParsedSplAccount(
        accountPublicKey: conflictingKey,
        mint: mint,
        rawAmount: 20,
        decimals: 6
      ),
      ParsedSplAccount(
        accountPublicKey: conflictingKey,
        mint: mint,
        rawAmount: 30,
        decimals: 6
      ),
    ])

    XCTAssertEqual(result.accounts, [identical])
    XCTAssertEqual(
      result.warnings,
      [
        "Solana repeated one identical token account record; the duplicate was skipped to avoid double-counting.",
        "Solana returned conflicting data for one repeated token account; every version was skipped.",
      ]
    )
  }

  func testSolanaDuplicateWarningsUsePluralGrammarForCountTwo() {
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let identical = ParsedSplAccount(
      accountPublicKey: "So11111111111111111111111111111111111111112",
      mint: mint,
      rawAmount: 10,
      decimals: 6
    )
    let result = NativeScanner.deduplicateSolanaAccounts([
      identical,
      identical,
      identical,
      ParsedSplAccount(
        accountPublicKey: "11111111111111111111111111111111",
        mint: mint,
        rawAmount: 20,
        decimals: 6
      ),
      ParsedSplAccount(
        accountPublicKey: "11111111111111111111111111111111",
        mint: mint,
        rawAmount: 30,
        decimals: 6
      ),
      ParsedSplAccount(
        accountPublicKey: mint,
        mint: mint,
        rawAmount: 40,
        decimals: 6
      ),
      ParsedSplAccount(
        accountPublicKey: mint,
        mint: mint,
        rawAmount: 50,
        decimals: 6
      ),
    ])

    XCTAssertEqual(result.accounts, [identical])
    XCTAssertEqual(
      result.warnings,
      [
        "Solana repeated 2 identical token account records; the duplicates were skipped to avoid double-counting.",
        "Solana returned conflicting data for 2 repeated token accounts; every version was skipped.",
      ]
    )

    let secondTaintedAccount = ParsedSplAccount(
      accountPublicKey: "11111111111111111111111111111111",
      mint: mint,
      rawAmount: 20,
      decimals: 6
    )
    let tainted = NativeScanner.deduplicateSolanaAccounts(
      [identical, secondTaintedAccount],
      taintedAccountPublicKeys: [identical.accountPublicKey, secondTaintedAccount.accountPublicKey]
    )
    XCTAssertTrue(tainted.accounts.isEmpty)
    XCTAssertEqual(
      tainted.warnings,
      [
        "Solana discarded 2 token accounts because malformed duplicates used the same public keys."
      ]
    )
  }

  func testSolanaTokenAmountRequiresUnsignedDecimalUInt64Grammar() throws {
    for invalidAmount in ["1.5", "1e6", "+1", "01", "18446744073709551616"] {
      let data = try solanaTokenAccountsResponseData([
        solanaTokenAccountJSON(
          publicKey: "So11111111111111111111111111111111111111112",
          accountProgram: SolanaTokenFixture.legacyProgram,
          rawAmount: invalidAmount,
          decimals: 6
        )
      ])
      let response = try JSONDecoder.addressAtlas.decode(
        SolanaTokenAccountsResponse.self,
        from: data
      )

      XCTAssertTrue(
        NativeScanner.parseSolanaTokenAccounts(
          response.result?.value ?? [],
          expectedOwner: SolanaTokenFixture.owner,
          expectedProgram: SolanaTokenFixture.legacyProgram
        ).isEmpty,
        "Expected \(invalidAmount) to be rejected"
      )
    }

    let maximumData = try solanaTokenAccountsResponseData([
      solanaTokenAccountJSON(
        publicKey: "So11111111111111111111111111111111111111112",
        accountProgram: SolanaTokenFixture.legacyProgram,
        rawAmount: "18446744073709551615",
        decimals: 6
      )
    ])
    let maximumResponse = try JSONDecoder.addressAtlas.decode(
      SolanaTokenAccountsResponse.self,
      from: maximumData
    )
    XCTAssertEqual(
      NativeScanner.parseSolanaTokenAccounts(
        maximumResponse.result?.value ?? [],
        expectedOwner: SolanaTokenFixture.owner,
        expectedProgram: SolanaTokenFixture.legacyProgram
      ).first?.rawAmount,
      Double(UInt64.max)
    )
  }

  func testSolanaResponseBindingMismatchTaintsPublicKeyAcrossProgramCalls() async throws {
    let publicKey = "So11111111111111111111111111111111111111112"
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: SolanaTokenFixture.mint,
      decimals: 6
    )

    for mismatchedField in ["account.owner", "parsed.type", "info.owner"] {
      for mismatchLegacyProgram in [true, false] {
        let http = StubHTTPClient { request in
          let program = requestedSolanaProgram(in: request)
          let shouldMismatch =
            (program == SolanaTokenFixture.legacyProgram) == mismatchLegacyProgram
          let accountProgram =
            shouldMismatch && mismatchedField == "account.owner"
            ? "11111111111111111111111111111111"
            : program
          let parsedType =
            shouldMismatch && mismatchedField == "parsed.type" ? "mint" : "account"
          let walletOwner =
            shouldMismatch && mismatchedField == "info.owner"
            ? publicKey
            : SolanaTokenFixture.owner
          let data = try solanaTokenAccountsResponseData([
            solanaTokenAccountJSON(
              publicKey: publicKey,
              accountProgram: accountProgram,
              parsedType: parsedType,
              walletOwner: walletOwner,
              rawAmount: "1",
              decimals: 6
            )
          ])
          return (data, httpResponse(for: request))
        }
        let scanner = NativeScanner(
          http: JSONHTTPClient(http: http),
          priceProvider: StaticPriceProvider(values: [:])
        )

        let result = try await scanner.fetchSolanaTokenBalances(
          rpc: URL(string: "https://solana.example")!,
          owner: SolanaTokenFixture.owner,
          registry: [token]
        )

        XCTAssertTrue(
          result.balances.isEmpty,
          "Expected \(mismatchedField) from either program to taint the shared public key"
        )
        XCTAssertEqual(
          result.warnings.first,
          "Solana discarded one token account because a malformed duplicate used the same public key."
        )
        XCTAssertTrue(result.warnings.contains { $0.contains("invalid parsed data") })
      }
    }
  }

  func testSolanaSamePublicKeyCannotBelongToBothTokenPrograms() async throws {
    let publicKey = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let program = requestedSolanaProgram(in: request)
      let data = try solanaTokenAccountsResponseData([
        solanaTokenAccountJSON(
          publicKey: publicKey,
          accountProgram: program,
          rawAmount: "1",
          decimals: 6
        )
      ])
      return (data, httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.fetchSolanaTokenBalances(
      rpc: URL(string: "https://solana.example")!,
      owner: SolanaTokenFixture.owner,
      registry: [
        TokenConfig(
          symbol: "USDC",
          name: "USD Coin",
          address: SolanaTokenFixture.mint,
          decimals: 6
        )
      ]
    )

    XCTAssertTrue(result.balances.isEmpty)
    XCTAssertEqual(
      result.warnings,
      [
        "Solana returned conflicting data for one repeated token account; every version was skipped."
      ]
    )
  }

  func testSolanaMintDecimalsDisagreementIsPermutationInvariantAndSkipsMint() async throws {
    let records = [
      ("So11111111111111111111111111111111111111112", "1", 6),
      ("11111111111111111111111111111111", "1", 9),
    ]
    var warningSnapshots: [[String]] = []

    for permutation in [records, Array(records.reversed())] {
      let accounts = permutation.map { publicKey, rawAmount, decimals in
        solanaTokenAccountJSON(
          publicKey: publicKey,
          accountProgram: SolanaTokenFixture.legacyProgram,
          rawAmount: rawAmount,
          decimals: decimals
        )
      }
      let http = StubHTTPClient { request in
        let program = requestedSolanaProgram(in: request)
        let responseAccounts =
          program == SolanaTokenFixture.legacyProgram ? accounts : []
        return (
          try solanaTokenAccountsResponseData(responseAccounts),
          httpResponse(for: request)
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: StaticPriceProvider(values: [:])
      )

      let result = try await scanner.fetchSolanaTokenBalances(
        rpc: URL(string: "https://solana.example")!,
        owner: SolanaTokenFixture.owner,
        registry: [
          TokenConfig(
            symbol: "USDC",
            name: "USD Coin",
            address: SolanaTokenFixture.mint,
            decimals: 6
          )
        ]
      )

      XCTAssertTrue(result.balances.isEmpty)
      XCTAssertTrue(result.warnings.contains { $0.contains("inconsistent on-chain decimals") })
      warningSnapshots.append(result.warnings)
    }

    XCTAssertEqual(warningSnapshots[0], warningSnapshots[1])
  }

  func testSolanaMintRawOverflowIsPermutationInvariantAndSkipsMint() async throws {
    let records = [
      ("So11111111111111111111111111111111111111112", String(UInt64.max)),
      ("11111111111111111111111111111111", "1"),
    ]
    var warningSnapshots: [[String]] = []

    for permutation in [records, Array(records.reversed())] {
      let accounts = permutation.map { publicKey, rawAmount in
        solanaTokenAccountJSON(
          publicKey: publicKey,
          accountProgram: SolanaTokenFixture.legacyProgram,
          rawAmount: rawAmount,
          decimals: 6
        )
      }
      let http = StubHTTPClient { request in
        let program = requestedSolanaProgram(in: request)
        let responseAccounts =
          program == SolanaTokenFixture.legacyProgram ? accounts : []
        return (
          try solanaTokenAccountsResponseData(responseAccounts),
          httpResponse(for: request)
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: StaticPriceProvider(values: [:])
      )

      let result = try await scanner.fetchSolanaTokenBalances(
        rpc: URL(string: "https://solana.example")!,
        owner: SolanaTokenFixture.owner,
        registry: [
          TokenConfig(
            symbol: "USDC",
            name: "USD Coin",
            address: SolanaTokenFixture.mint,
            decimals: 6
          )
        ]
      )

      XCTAssertTrue(result.balances.isEmpty)
      XCTAssertTrue(result.warnings.contains { $0.contains("supported numeric range") })
      warningSnapshots.append(result.warnings)
    }

    XCTAssertEqual(warningSnapshots[0], warningSnapshots[1])
  }

  func testSolanaRawAmountsAreAddedExactlyBeforeScalingOnce() async throws {
    let records = [
      ("So11111111111111111111111111111111111111112", "9007199254740993"),
      ("11111111111111111111111111111111", "1"),
    ]
    var amounts: [Double] = []

    for permutation in [records, Array(records.reversed())] {
      let accounts = permutation.map { publicKey, rawAmount in
        solanaTokenAccountJSON(
          publicKey: publicKey,
          accountProgram: SolanaTokenFixture.legacyProgram,
          rawAmount: rawAmount,
          decimals: 0
        )
      }
      let http = StubHTTPClient { request in
        let program = requestedSolanaProgram(in: request)
        let responseAccounts =
          program == SolanaTokenFixture.legacyProgram ? accounts : []
        return (
          try solanaTokenAccountsResponseData(responseAccounts),
          httpResponse(for: request)
        )
      }
      let scanner = NativeScanner(
        http: JSONHTTPClient(http: http),
        priceProvider: StaticPriceProvider(values: [:])
      )

      let result = try await scanner.fetchSolanaTokenBalances(
        rpc: URL(string: "https://solana.example")!,
        owner: SolanaTokenFixture.owner,
        registry: [
          TokenConfig(
            symbol: "USDC",
            name: "USD Coin",
            address: SolanaTokenFixture.mint,
            decimals: 0
          )
        ]
      )

      amounts.append(try XCTUnwrap(result.balances.first?.amount))
    }

    XCTAssertEqual(amounts, [9_007_199_254_740_994, 9_007_199_254_740_994])
  }

  func testSolanaMalformedDuplicateTaintsPublicKeyAcrossProgramResultsInEitherOrder()
    async throws
  {
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let owner = "So11111111111111111111111111111111111111112"
    let token = TokenConfig(
      symbol: "USDC",
      name: "USD Coin",
      address: mint,
      decimals: 6
    )

    for malformedAmount in ["1.5", "01"] {
      for malformedLegacyProgram in [true, false] {
        let http = StubHTTPClient { request in
          let program = requestedSolanaProgram(in: request)
          let isLegacyProgram = program == SolanaTokenFixture.legacyProgram
          let amount = isLegacyProgram == malformedLegacyProgram ? malformedAmount : "1"
          let data = try solanaTokenAccountsResponseData([
            solanaTokenAccountJSON(
              publicKey: owner,
              accountProgram: program,
              walletOwner: owner,
              mint: mint,
              rawAmount: amount,
              decimals: 6
            )
          ])
          return (data, httpResponse(for: request))
        }
        let scanner = NativeScanner(
          http: JSONHTTPClient(http: http),
          priceProvider: StaticPriceProvider(values: [:])
        )

        let result = try await scanner.fetchSolanaTokenBalances(
          rpc: URL(string: "https://solana.example")!,
          owner: owner,
          registry: [token]
        )

        XCTAssertTrue(result.balances.isEmpty)
        XCTAssertEqual(
          result.warnings.first,
          "Solana discarded one token account because a malformed duplicate used the same public key."
        )
      }
    }
  }

  func testSolanaDuplicateComparisonPreservesCheckedUInt64Amounts() async throws {
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let owner = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let program = requestedSolanaProgram(in: request)
      let amount =
        program == SolanaTokenFixture.legacyProgram
        ? "18446744073709551615"
        : "18446744073709551614"
      let data = try solanaTokenAccountsResponseData([
        solanaTokenAccountJSON(
          publicKey: owner,
          accountProgram: program,
          walletOwner: owner,
          mint: mint,
          rawAmount: amount,
          decimals: 6
        )
      ])
      return (data, httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.fetchSolanaTokenBalances(
      rpc: URL(string: "https://solana.example")!,
      owner: owner,
      registry: [
        TokenConfig(symbol: "USDC", name: "USD Coin", address: mint, decimals: 6)
      ]
    )

    XCTAssertTrue(result.balances.isEmpty)
    XCTAssertEqual(
      result.warnings,
      [
        "Solana returned conflicting data for one repeated token account; every version was skipped."
      ]
    )
  }

  func testSolanaStandaloneMalformedIdentityAlwaysProducesWarning() async throws {
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let owner = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let program = requestedSolanaProgram(in: request)
      let accounts =
        program == SolanaTokenFixture.legacyProgram
        ? [
          solanaTokenAccountJSON(
            publicKey: owner,
            accountProgram: program,
            walletOwner: owner,
            mint: "not-a-solana-mint",
            rawAmount: "1",
            decimals: 6
          )
        ]
        : []
      return (try solanaTokenAccountsResponseData(accounts), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.fetchSolanaTokenBalances(
      rpc: URL(string: "https://solana.example")!,
      owner: owner,
      registry: [
        TokenConfig(symbol: "USDC", name: "USD Coin", address: mint, decimals: 6)
      ]
    )

    XCTAssertTrue(result.balances.isEmpty)
    XCTAssertEqual(
      result.warnings,
      ["Some SPL token accounts returned invalid parsed data; balances may be incomplete."]
    )
  }

  func testSolanaScannerSurfacesPartialTokenProgramWarnings() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
          { "jsonrpc": "2.0", "id": 1, "result": { "context": { "slot": 123 }, "value": 1000000000 } }
          """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getTokenAccountsByOwner") {
        throw URLError(.timedOut)
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["solana": PricePoint(usd: 10)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first?.symbol, "SOL")
    XCTAssertEqual(result.holdings.first?.valueUsd, 10)
    XCTAssertTrue(
      result.warnings.contains { warning in
        warning.contains("Solana") && warning.contains("SPL Token token account scan failed")
      })
    XCTAssertTrue(
      result.warnings.contains { warning in
        warning.contains("Solana") && warning.contains("Token-2022 token account scan failed")
      })
  }

  func testSolanaNativeErrorUsesValidatedSlotFallbackForTokenReads() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let requests = ScannerRequestLog()
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
            { "jsonrpc": "2.0", "id": 1, "error": { "code": -32000, "message": "node is behind" } }
          """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getSlot") {
        return (
          Data(#"{"jsonrpc":"2.0","id":3,"result":123}"#.utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("getTokenAccountsByOwner") {
        let program = requestedSolanaProgram(in: request)
        let slot: UInt64 =
          program == SolanaTokenFixture.token2022Program
            || requestedSolanaMinimumSlot(in: request) == 124
          ? 124 : 123
        return (
          try solanaTokenAccountsResponseData([], slot: slot),
          httpResponse(for: request)
        )
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["solana": PricePoint(usd: 10)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertFalse(result.holdings.contains { $0.symbol == "SOL" })
    XCTAssertTrue(
      result.warnings.contains { warning in
        warning.contains("Solana") && warning.contains("node is behind")
      })
    XCTAssertEqual(
      requests.snapshot().filter { request in
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
          .contains("getTokenAccountsByOwner")
      }.count,
      3
    )
    XCTAssertEqual(
      requests.snapshot()
        .filter {
          requestedSolanaMethod(in: $0) == "getTokenAccountsByOwner"
            && requestedSolanaProgram(in: $0) == SolanaTokenFixture.legacyProgram
        }
        .compactMap(requestedSolanaMinimumSlot)
        .sorted(),
      [123, 124]
    )
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("snapshot slot could not") }))
  }

  func testSolanaRejectsMismatchedSlotFallbackBeforeTokenReads() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let requests = ScannerRequestLog()
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      if body.contains("getBalance") {
        return (
          Data(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"node is behind"}}"#
              .utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("getSlot") {
        return (
          Data(#"{"jsonrpc":"2.0","id":99,"result":123}"#.utf8),
          httpResponse(for: request)
        )
      }
      XCTFail("Token reads must not start without a validated snapshot-slot response.")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("snapshot slot could not") }))
  }

}
