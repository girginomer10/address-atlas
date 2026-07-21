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

private func solanaTokenAccountsResponseData(_ accounts: [[String: Any]]) throws -> Data {
  try JSONSerialization.data(withJSONObject: ["result": ["value": accounts]])
}

private func requestedSolanaProgram(in request: URLRequest) -> String {
  let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  return body.contains(SolanaTokenFixture.token2022Program)
    ? SolanaTokenFixture.token2022Program
    : SolanaTokenFixture.legacyProgram
}

extension NativeScannerTokenTests {
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
          { "result": { "value": 1000000000 } }
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

  func testSolanaJsonRpcErrorsDoNotBecomeZeroBalances() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
          { "error": { "code": -32000, "message": "node is behind" } }
          """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getTokenAccountsByOwner") {
        let json = """
          { "result": { "value": [] } }
          """
        return (Data(json.utf8), httpResponse(for: request))
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
  }

}
