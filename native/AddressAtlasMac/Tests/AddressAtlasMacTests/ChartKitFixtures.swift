import Foundation

import AddressAtlasCore
@testable import AddressAtlasMac

/// Synthetic portfolio for the chart tests and screenshots, shaped like the one
/// in `docs/design/views.html`. Round prices and amounts, placeholder
/// addresses, no real wallet.
///
///     BTC   Cold storage 0.362 (liquid), Kraken 0.05            $27,980
///     ETH   Main/Ethereum 2.6, Main/Base 1.0, Kraken 0.5        $13,120
///     SOL   Phantom 12.5 liquid, 26 staked                      $5,082
///     ATOM  Keplr 4.2 liquid, 280 staked, 24.79 unbonding,
///           1.21 rewards                                        $2,109
///     USDC  Kraken 920.05                                       $920
///     ZKT   Main/Ethereum 1,250, no price                       (unpriced)
enum ChartKitFixtures {
  static let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
  static let evmAddress = "0x0000000000000000000000000000000000000001"
  static let solanaAddress = "11111111111111111111111111111111"
  static let cosmosAddress = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
  static let krakenID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

  static let btcPrice = 67_912.86
  static let ethPrice = 3_200.0
  static let solPrice = 132.0
  static let atomPrice = 6.8
  static let usdcPrice = 1.0

  static func wallet(
    _ symbol: String, name: String, amount: Double, price: Double?,
    source: AssetSource = .native, family: ChainFamily, chainId: String, chainName: String,
    address: String, label: String
  ) -> TrackedAsset {
    TrackedAsset(
      id: "\(address)-\(chainId)-\(symbol)-\(source.rawValue)",
      address: address, chainId: chainId, chainName: chainName, family: family,
      symbol: symbol, name: name, amount: amount,
      priceUsd: price ?? 0, valueUsd: price.map { $0 * amount } ?? 0,
      pricingStatus: price == nil ? .unpriced : .priced,
      source: source, walletLabel: label
    )
  }

  static func kraken(_ symbol: String, name: String, amount: Double, price: Double) -> TrackedAsset {
    TrackedAsset(
      id: "\(krakenID.uuidString)-kraken-\(symbol)",
      address: "Kraken", chainId: "kraken", chainName: "Kraken", family: .exchange,
      symbol: symbol, name: name, amount: amount, priceUsd: price, valueUsd: price * amount,
      pricingStatus: .priced, source: .exchange, walletLabel: "Kraken",
      exchangeId: krakenID, exchangeProvider: .kraken
    )
  }

  static func portfolio(includeUnpriced: Bool = true) -> [TrackedAsset] {
    var holdings: [TrackedAsset] = [
      wallet(
        "BTC", name: "Bitcoin", amount: 0.362, price: btcPrice, family: .bitcoin,
        chainId: "bitcoin", chainName: "Bitcoin", address: bitcoinAddress, label: "Cold storage"),
      kraken("BTC", name: "Bitcoin", amount: 0.05, price: btcPrice),
      wallet(
        "ETH", name: "Ethereum", amount: 2.6, price: ethPrice, family: .evm, chainId: "ethereum",
        chainName: "Ethereum", address: evmAddress, label: "Main"),
      wallet(
        "ETH", name: "Ethereum", amount: 1.0, price: ethPrice, family: .evm, chainId: "base",
        chainName: "Base", address: evmAddress, label: "Main"),
      kraken("ETH", name: "Ethereum", amount: 0.5, price: ethPrice),
      wallet(
        "SOL", name: "Solana", amount: 12.5, price: solPrice, family: .solana, chainId: "solana",
        chainName: "Solana", address: solanaAddress, label: "Phantom"),
      wallet(
        "SOL", name: "Solana", amount: 26, price: solPrice, source: .staked, family: .solana,
        chainId: "solana", chainName: "Solana", address: solanaAddress, label: "Phantom"),
    ]
    for (source, amount) in [
      (AssetSource.native, 4.2), (.staked, 280), (.unbonding, 24.79), (.rewards, 1.21),
    ] {
      holdings.append(
        wallet(
          "ATOM", name: "Cosmos Hub", amount: amount, price: atomPrice, source: source,
          family: .cosmos, chainId: "cosmoshub", chainName: "Cosmos Hub",
          address: cosmosAddress, label: "Keplr"))
    }
    holdings.append(kraken("USDC", name: "USD Coin", amount: 920.05, price: usdcPrice))
    if includeUnpriced {
      holdings.append(
        wallet(
          "ZKT", name: "Zeta Kite Token", amount: 1_250, price: nil, source: .erc20,
          family: .evm, chainId: "ethereum", chainName: "Ethereum", address: evmAddress,
          label: "Main"))
    }
    return holdings
  }

  /// One coin's holdings, as the coin detail screen passes them.
  static func ethOnly() -> [TrackedAsset] {
    portfolio().filter { $0.symbol == "ETH" }
  }

  /// Forty small coins on top of the portfolio, to exercise folding.
  static func crowdedPortfolio() -> [TrackedAsset] {
    var holdings = portfolio()
    for index in 0..<40 {
      holdings.append(
        wallet(
          "T\(index)", name: "Token \(index)", amount: Double(10 + index), price: 1.0 + Double(index) * 0.05,
          source: .erc20, family: .evm, chainId: "ethereum", chainName: "Ethereum",
          address: evmAddress, label: "Main"))
    }
    return holdings
  }
}
