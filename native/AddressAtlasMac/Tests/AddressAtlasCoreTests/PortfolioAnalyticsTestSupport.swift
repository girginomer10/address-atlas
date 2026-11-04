import Foundation

@testable import AddressAtlasCore

/// Synthetic portfolio used by the analytics tests: round prices, round
/// amounts, and public placeholder addresses only.
///
///     BTC   Cold storage 0.5 (liquid)   Kraken 0.1 (on exchange)      $36,000
///     ETH   Main/Ethereum 2.0, Main/Base 1.0, Kraken 0.5              $10,500
///     SOL   Phantom 10 liquid + 20 staked                             $3,000
///     ATOM  Keplr 4 liquid, 200 staked, 20 unbonding, 1 rewards       $1,125
///     USDC  Kraken 900                                                $900
///                                                                     $51,525
enum PortfolioFixture {
  static let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
  static let evmAddress = "0x0000000000000000000000000000000000000001"
  static let solanaAddress = "11111111111111111111111111111111"
  static let cosmosAddress = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
  static let secondEvmAddress = "0x0000000000000000000000000000000000000002"
  static let krakenID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
  static let manualID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
  static let unlock = Date(timeIntervalSince1970: 1_800_000_000)

  struct Prices {
    var btc = 60_000.0
    var eth = 3_000.0
    var sol = 100.0
    var atom = 5.0
    var usdc = 1.0
  }

  static func wallet(
    _ symbol: String,
    amount: Double,
    price: Double?,
    source: AssetSource = .native,
    family: ChainFamily,
    chainId: String,
    chainName: String,
    address: String,
    label: String,
    unlocksAt: Date? = nil,
    idSuffix: String? = nil
  ) -> TrackedAsset {
    TrackedAsset(
      id: "\(address)-\(chainId)-\(symbol)-\(source.rawValue)" + (idSuffix.map { "-\($0)" } ?? ""),
      address: address,
      chainId: chainId,
      chainName: chainName,
      family: family,
      symbol: symbol,
      name: "\(chainName) \(symbol)",
      amount: amount,
      priceUsd: price ?? 0,
      valueUsd: price.map { $0 * amount } ?? 0,
      pricingStatus: price == nil ? .unpriced : .priced,
      source: source,
      walletLabel: label,
      unlocksAt: unlocksAt
    )
  }

  static func kraken(_ symbol: String, amount: Double, price: Double?) -> TrackedAsset {
    TrackedAsset(
      id: "\(krakenID.uuidString)-kraken-\(symbol)",
      address: "Kraken",
      chainId: "kraken",
      chainName: "Kraken",
      family: .exchange,
      symbol: symbol,
      name: symbol,
      amount: amount,
      priceUsd: price ?? 0,
      valueUsd: price.map { $0 * amount } ?? 0,
      pricingStatus: price == nil ? .unpriced : .priced,
      source: .exchange,
      walletLabel: "Kraken",
      exchangeId: krakenID,
      exchangeProvider: .kraken
    )
  }

  static func manual(
    _ symbol: String, amount: Double, price: Double, venue: String = "Ledger"
  ) -> TrackedAsset {
    TrackedAsset(
      id: "manual-\(manualID.uuidString)",
      address: "Hardware wallet",
      chainId: "manual-Manual",
      chainName: venue,
      family: .exchange,
      symbol: symbol,
      name: symbol,
      amount: amount,
      priceUsd: price,
      valueUsd: price * amount,
      pricingStatus: .priced,
      source: .exchange
    )
  }

  /// The portfolio in the type comment, with every coin's price adjustable and
  /// the Base ETH amount adjustable (the one amount attribution tests move).
  static func portfolio(
    prices: Prices = Prices(),
    baseEth: Double = 1.0,
    includeSolana: Bool = true
  ) -> [TrackedAsset] {
    var holdings = [
      wallet(
        "BTC", amount: 0.5, price: prices.btc, family: .bitcoin, chainId: "bitcoin",
        chainName: "Bitcoin", address: bitcoinAddress, label: "Cold storage"),
      kraken("BTC", amount: 0.1, price: prices.btc),
      wallet(
        "ETH", amount: 2.0, price: prices.eth, family: .evm, chainId: "ethereum",
        chainName: "Ethereum", address: evmAddress, label: "Main"),
      wallet(
        "ETH", amount: baseEth, price: prices.eth, family: .evm, chainId: "base",
        chainName: "Base", address: evmAddress, label: "Main"),
      kraken("ETH", amount: 0.5, price: prices.eth),
      wallet(
        "ATOM", amount: 4, price: prices.atom, family: .cosmos, chainId: "cosmoshub",
        chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
      wallet(
        "ATOM", amount: 200, price: prices.atom, source: .staked, family: .cosmos,
        chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
      wallet(
        "ATOM", amount: 20, price: prices.atom, source: .unbonding, family: .cosmos,
        chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr",
        unlocksAt: unlock, idSuffix: "1800000000"),
      wallet(
        "ATOM", amount: 1, price: prices.atom, source: .rewards, family: .cosmos,
        chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
      kraken("USDC", amount: 900, price: prices.usdc),
    ]
    if includeSolana {
      holdings += [
        wallet(
          "SOL", amount: 10, price: prices.sol, family: .solana, chainId: "solana",
          chainName: "Solana", address: solanaAddress, label: "Phantom"),
        wallet(
          "SOL", amount: 20, price: prices.sol, source: .staked, family: .solana,
          chainId: "solana", chainName: "Solana", address: solanaAddress, label: "Phantom"),
      ]
    }
    return holdings
  }

  static func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
  }

  static func run(
    _ text: String,
    _ holdings: [TrackedAsset],
    id: String? = nil,
    inputCount: Int = 5
  ) -> ScanRunRecord {
    ScanRunRecord(
      id: id.flatMap(UUID.init(uuidString:)) ?? UUID(),
      generatedAt: date(text),
      totalUsd: holdings.filter { $0.pricingStatus == .priced }.map(\.valueUsd).reduce(0, +),
      inputCount: inputCount,
      holdings: holdings
    )
  }
}
