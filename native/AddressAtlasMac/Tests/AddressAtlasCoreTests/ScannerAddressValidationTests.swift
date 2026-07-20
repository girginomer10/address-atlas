import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class ScannerAddressValidationTests: XCTestCase {
  func testEvmMixedCaseAddressesRequireAValidEIP55Checksum() {
    let officialValid = [
      "0x52908400098527886E0F7030069857D2E4169EE7",
      "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
      "0xde709f2102306220921060314715629080e2fb77",
      "0x27b1fdb04752bbc536007a920d24acb045561c26",
      "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
      "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
      "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
      "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    ]
    for address in officialValid {
      XCTAssertFalse(AddressDetection.detectChains(for: address).isEmpty, address)
    }

    for valid in officialValid
    where valid.dropFirst(2).contains(where: { $0.isLowercase })
      && valid.dropFirst(2).contains(where: { $0.isUppercase })
    {
      var characters = Array(valid)
      let index = characters[2...].firstIndex(where: { $0.isLetter })!
      characters[index] =
        characters[index].isUppercase
        ? Character(characters[index].lowercased())
        : Character(characters[index].uppercased())
      let invalid = String(characters)
      XCTAssertTrue(AddressDetection.detectChains(for: invalid).isEmpty, invalid)
    }
  }

  func testCosmosValidationAcceptsLegacyAnd32ByteAccountAddresses() {
    let modern = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"

    XCTAssertEqual(AddressDetection.detectChains(for: modern).map(\.id), ["cosmoshub"])
    XCTAssertEqual(AddressDetection.canonicalAddress(modern, family: .cosmos), modern)
  }

  func testRetiredStargazeRemainsCanonicalForPersistedRecordsButIsNotScannable() {
    let address = "stars1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqspal9j"

    XCTAssertEqual(AddressDetection.retiredCosmosNetworkName(for: address), "Stargaze")
    XCTAssertEqual(AddressDetection.canonicalAddress(address, family: .cosmos), address)
    XCTAssertTrue(AddressDetection.detectChains(for: address).isEmpty)
    XCTAssertFalse(ChainRegistry.allChains.contains(where: { $0.id == "stargaze" }))
  }

  func testRegistryUsesCurrentPolygonRPCAndOptimismUSDTContract() {
    XCTAssertEqual(
      ChainRegistry.evmChains.first(where: { $0.id == "polygon" })?.rpcUrl?.absoluteString,
      "https://polygon.drpc.org"
    )
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["optimism"]?.first(where: { $0.symbol == "USDT" })?.address,
      "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58"
    )
  }

  func testChainSpecificValidationDoesNotMisclassifySolanaAsBitcoin() {
    XCTAssertEqual(
      AddressDetection.detectChains(for: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT").map(\.family),
      [.bitcoin]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh").map(
        \.family),
      [.bitcoin]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "11111111111111111111111111111111").map(\.family),
      [.solana]
    )
    XCTAssertTrue(AddressDetection.detectChains(for: "1BoatSLRHtKNngkdXEeobR76b53LETtpyU").isEmpty)
    XCTAssertTrue(AddressDetection.detectChains(for: String(repeating: "2", count: 10_000)).isEmpty)
  }

  func testCustomTokenCanonicalizationAndScannerBoundaryValidation() {
    let valid = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: " 0x0000000000000000000000000000000000000001 ",
      symbol: " TEST ",
      name: " Test Token ",
      decimals: 18,
      coinGeckoId: " Test-Token ",
      priceUsd: 2
    )
    let invalidAddress = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "not-a-contract",
      symbol: "BADADDR",
      name: "Bad Address",
      decimals: 18
    )
    let invalidDecimals = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000002",
      symbol: "BADDEC",
      name: "Bad Decimals",
      decimals: 37
    )
    let invalidPrice = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000003",
      symbol: "BADPRICE",
      name: "Bad Price",
      decimals: 18,
      priceUsd: .infinity
    )
    let invalidCoinGeckoId = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000004",
      symbol: "BADID",
      name: "Bad CoinGecko ID",
      decimals: 18,
      coinGeckoId: "tökén"
    )
    let mismatchedChain = CustomTokenRecord(
      chainKind: .solana,
      chainId: "ethereum",
      address: "11111111111111111111111111111111",
      symbol: "BADCHAIN",
      name: "Bad Chain",
      decimals: 9
    )

    let registries = NativeScanner.tokenRegistries(
      customTokens: [
        valid, invalidAddress, invalidDecimals, invalidPrice, invalidCoinGeckoId, mismatchedChain,
      ]
    )
    let added = registries.evm["ethereum"]?.first(where: { $0.symbol == "TEST" })
    let legacyInvalidID = registries.evm["ethereum"]?.first(where: { $0.symbol == "BADID" })

    XCTAssertEqual(added?.address, "0x0000000000000000000000000000000000000001")
    XCTAssertEqual(added?.coinGeckoId, "test-token")
    XCTAssertEqual(legacyInvalidID?.address, "0x0000000000000000000000000000000000000004")
    XCTAssertNil(legacyInvalidID?.coinGeckoId)
    XCTAssertFalse(
      registries.evm["ethereum"]?.contains(where: {
        ["BADADDR", "BADDEC", "BADPRICE", "BADCHAIN"].contains($0.symbol)
      }) ?? true)
    XCTAssertEqual(registries.warnings.count, 5)
    XCTAssertTrue(
      registries.warnings.contains(where: {
        $0.contains("BADID") && $0.contains("CoinGecko pricing was disabled")
      }))
    XCTAssertTrue(AddressDetection.isValidCustomTokenAddress(valid.address, family: .evm))
    XCTAssertEqual(AddressDetection.canonicalAddress(valid.address, family: .evm), added?.address)
  }

  func testRegistryUsesPOLAndDoesNotMislabelSolanaSoBTC() throws {
    let polygon = try XCTUnwrap(ChainRegistry.evmChains.first(where: { $0.id == "polygon" }))
    XCTAssertEqual(polygon.symbol, "POL")
    XCTAssertEqual(polygon.coinGeckoId, "polygon-ecosystem-token")
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["MATIC"], "polygon-ecosystem-token")
    XCTAssertFalse(
      ChainRegistry.commonSplTokens["solana"]?.contains(where: {
        $0.address == "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E" || $0.symbol == "WBTC"
      }) ?? true)
  }

  func testExplorerURLBuilderSupportsFragmentAndPathBasedExplorers() {
    let tronAddress = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"

    XCTAssertEqual(
      ChainRegistry.tron.explorerURL(for: tronAddress).absoluteString,
      "https://tronscan.org/#/address/\(tronAddress)"
    )
    XCTAssertEqual(
      ChainRegistry.bitcoin.explorerURL(for: bitcoinAddress).absoluteString,
      "https://blockstream.info/address/\(bitcoinAddress)"
    )
  }

  func testAddressParsingReportsTruncation() {
    let input = (1...3)
      .map { String(format: "0x%040llx", UInt64($0)) }
      .joined(separator: " ")

    let parsed = AddressDetection.parseWithMetadata(input, maxCount: 2)

    XCTAssertEqual(parsed.addresses.count, 2)
    XCTAssertTrue(parsed.wasTruncated)
  }

  func testExistingVaultCustomTokensAreCappedAtOneHundred() {
    let tokens = (0..<101).map { index in
      CustomTokenRecord(
        chainKind: .evm,
        chainId: "ethereum",
        address: String(format: "0x%040llx", UInt64(index + 1_000)),
        symbol: "CAP\(index)",
        name: "Capped Token \(index)",
        decimals: 18
      )
    }

    let registries = NativeScanner.tokenRegistries(customTokens: tokens)
    let customSymbols =
      registries.evm["ethereum"]?.filter { $0.symbol.hasPrefix("CAP") }.map(\.symbol) ?? []

    XCTAssertEqual(customSymbols.count, 100)
    XCTAssertFalse(customSymbols.contains("CAP100"))
    XCTAssertTrue(registries.warnings.contains(where: { $0.contains("first 100") }))
  }
}
