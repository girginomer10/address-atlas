import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class NativeScannerTokenTests: XCTestCase {
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

      if bodyText.contains("\"eth_getBalance\"") {
        return (Data(#"{"result":"0x0"}"#.utf8), httpResponse(for: request))
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

  func testChainRegistryIncludesExpandedNetworksAndAssets() {
    let evmIds = Set(ChainRegistry.evmChains.map(\.id))
    XCTAssertTrue(evmIds.isSuperset(of: ["gnosis", "linea", "mantle", "scroll", "zksync-era"]))
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["gnosis"]?.first { $0.symbol == "GNO" }?.decimals, 18)
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["scroll"]?.first { $0.symbol == "USDC" }?.address,
      "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4"
    )
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["zksync-era"]?.first { $0.symbol == "ZK" }?.address,
      "0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E"
    )
    XCTAssertEqual(
      ChainRegistry.commonSplTokens["solana"]?.first { $0.symbol == "PYTH" }?.decimals, 6)
    for chainID in ["arbitrum", "polygon"] {
      let usdt0 = ChainRegistry.commonErc20Tokens[chainID]?.first { $0.symbol == "USDT0" }
      XCTAssertEqual(usdt0?.name, "USDT0")
      XCTAssertEqual(usdt0?.decimals, 6)
      XCTAssertEqual(usdt0?.coinGeckoId, "usdt0")
      XCTAssertFalse(
        ChainRegistry.commonErc20Tokens[chainID]?.contains { $0.symbol == "USDT" } == true)
    }
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["ZK"], "zksync")
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["SCR"], "scroll")
  }

  func testBuiltinRegistriesCoverReferenceTokenSet() {
    let registries = NativeScanner.tokenRegistries(customTokens: [])

    XCTAssertTrue(registries.evm["base"]?.contains { $0.symbol == "cbBTC" } == true)
    XCTAssertTrue(registries.evm["arbitrum"]?.contains { $0.symbol == "ARB" } == true)
    XCTAssertTrue(registries.evm["optimism"]?.contains { $0.symbol == "OP" } == true)
    XCTAssertTrue(registries.evm["bsc"]?.contains { $0.symbol == "CAKE" } == true)
    XCTAssertTrue(registries.evm["avalanche"]?.contains { $0.symbol == "BTC.b" } == true)

    let solana = registries.spl["solana"] ?? []
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "USDT" })?.address,
      "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
    )
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "BONK" })?.address,
      "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"
    )
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "WIF" })?.address,
      "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm"
    )
    XCTAssertTrue(solana.contains { $0.symbol == "JitoSOL" })
  }

  func testSolanaTokenAccountParserReadsJsonParsedBalances() throws {
    let json = """
      {
        "result": {
          "value": [
            {
              "account": {
                "data": {
                  "parsed": {
                    "info": {
                      "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                      "tokenAmount": {
                        "amount": "1234500",
                        "decimals": 6
                      }
                    }
                  }
                }
              }
            }
          ]
        }
      }
      """
    let response = try JSONDecoder.addressAtlas.decode(
      SolanaTokenAccountsResponse.self, from: Data(json.utf8))
    let parsed = NativeScanner.parseSolanaTokenAccounts(response.result?.value ?? [])

    XCTAssertEqual(
      parsed,
      [
        ParsedSplAccount(
          mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
          rawAmount: 1_234_500,
          decimals: 6
        )
      ])
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

  func testCosmosParsersReadLiquidStakedAndRewardsBalances() throws {
    let bankJSON = """
      { "balances": [{ "denom": "uatom", "amount": "1200000" }] }
      """
    let delegationJSON = """
      {
        "delegation_responses": [
          { "balance": { "denom": "uatom", "amount": "2500000" } },
          { "balance": { "denom": "uother", "amount": "9999999" } }
        ]
      }
      """
    let rewardsJSON = """
      { "total": [{ "denom": "uatom", "amount": "340000" }] }
      """

    let bank = try JSONDecoder.addressAtlas.decode(
      CosmosBankResponse.self, from: Data(bankJSON.utf8))
    let delegations = try JSONDecoder.addressAtlas.decode(
      CosmosDelegationResponse.self, from: Data(delegationJSON.utf8))
    let rewards = try JSONDecoder.addressAtlas.decode(
      CosmosRewardsResponse.self, from: Data(rewardsJSON.utf8))

    XCTAssertEqual(NativeScanner.parseCosmosLiquid(bank, denom: "uatom", decimals: 6), 1.2)
    XCTAssertEqual(
      NativeScanner.parseCosmosDelegations(delegations, denom: "uatom", decimals: 6), 2.5)
    XCTAssertEqual(NativeScanner.parseCosmosRewards(rewards, denom: "uatom", decimals: 6), 0.34)
  }

  func testTronTrc20ParserReadsRegisteredBalances() {
    let token = TokenConfig(
      symbol: "USDT",
      name: "Tether",
      address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
      decimals: 6,
      coinGeckoId: "tether"
    )

    let parsed = NativeScanner.parseTronTrc20Balances(
      [
        ["TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t": "1250000"],
        ["other": "999999"],
      ],
      tokens: [token]
    )

    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.token.symbol, "USDT")
    XCTAssertEqual(parsed.first?.amount, 1.25)
  }

  func testXrpTrustLineParserDecodesIssuedAssets() {
    let lines = [
      XrpTrustLine(
        account: "rIssuer111111111111111111111111111111111",
        balance: "42.5",
        currency: "5553440000000000000000000000000000000000"
      ),
      XrpTrustLine(
        account: "rIssuer222222222222222222222222222222222",
        balance: "-1",
        currency: "IGNORED"
      ),
    ]

    let parsed = NativeScanner.parseXrpTrustLines(
      lines,
      address: "rWallet111111111111111111111111111111111",
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
    let issuer = "rIssuer111111111111111111111111111111111"
    let parsed = NativeScanner.parseXrpTrustLines(
      [
        XrpTrustLine(account: issuer, balance: "1", currency: hexCodeBeginningWithUSD),
        XrpTrustLine(account: issuer, balance: "2", currency: lookalikeUSD),
      ],
      address: "rWallet111111111111111111111111111111111",
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
}
