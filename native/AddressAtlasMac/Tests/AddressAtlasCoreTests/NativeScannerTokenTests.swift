import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class NativeScannerTokenTests: XCTestCase {
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

}
