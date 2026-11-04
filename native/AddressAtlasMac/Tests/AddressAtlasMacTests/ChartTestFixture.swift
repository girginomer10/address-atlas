import AddressAtlasCore
import Foundation

@testable import AddressAtlasMac

/// Synthetic portfolio history for the chart tests and screenshots: public
/// placeholder addresses, round-ish amounts, and made-up prices.
///
/// Forty-two days (24 Sep to 4 Nov 2026) with a scan on most days and two scans
/// on some, 36 runs in all:
///
///   - prices drift and wobble per coin, deterministically;
///   - on day 20 a second EVM wallet ("Savings") is added, so the scans before
///     and after it do not read the same sources;
///   - on day 27 ATOM is unstaked: 24.79 ATOM moves from staked to unbonding,
///     unlocking on 16 Nov 2026;
///   - on day 41 Base receives 0.0094 ETH;
///   - days 3, 10, 17, 24, 31 and 38 have no scan.
enum ChartFixture {
  static let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
  static let evmAddress = "0x0000000000000000000000000000000000000001"
  static let savingsAddress = "0x0000000000000000000000000000000000000002"
  static let solanaAddress = "11111111111111111111111111111111"
  static let cosmosAddress = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
  static let krakenID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

  /// 24 Sep 2026, 09:00 UTC.
  static let firstScan = Date(timeIntervalSince1970: 1_790_240_400)
  static let dayCount = 42
  static let sourceChangeDay = 20
  static let unstakeDay = 27
  static let unlockDate = Date(timeIntervalSince1970: 1_794_787_200)  // 16 Nov 2026, 00:00 UTC

  static func scanDate(day: Int, hour: Int = 0) -> Date {
    firstScan.addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3_600)
  }

  // MARK: Prices

  private static func price(_ symbol: String, day: Int) -> Double {
    let d = Double(day)
    switch symbol {
    case "BTC": return 66_000 * (1 + 0.030 * d / 41) + 900 * sin(d * 0.45)
    case "ETH": return 3_050 * (1 + 0.050 * d / 41) + 70 * sin(d * 0.9 + 1)
    case "SOL": return 138 * (1 - 0.040 * d / 41) + 6 * sin(d * 0.6 + 2)
    case "ATOM": return 6.5 * (1 + 0.040 * d / 41) + 0.25 * sin(d * 0.7 + 3)
    case "LINK": return 15.2 * (1 + 0.020 * d / 41) + 0.5 * sin(d * 0.8)
    case "ARB": return 0.82 * (1 - 0.050 * d / 41) + 0.03 * sin(d * 1.1)
    case "DOGE": return 0.16 + 0.006 * sin(d * 0.5 + 4)
    case "USDC": return 1
    default: return 1
    }
  }

  // MARK: Holdings

  private static func wallet(
    _ symbol: String, amount: Double, day: Int, source: AssetSource = .native,
    family: ChainFamily, chainId: String, chainName: String, address: String, label: String,
    unlocksAt: Date? = nil, priced: Bool = true
  ) -> TrackedAsset {
    let unit = priced ? price(symbol, day: day) : 0
    return TrackedAsset(
      id: "\(address)-\(chainId)-\(symbol)-\(source.rawValue)", address: address,
      chainId: chainId, chainName: chainName, family: family, symbol: symbol,
      name: "\(chainName) \(symbol)", amount: amount, priceUsd: unit, valueUsd: unit * amount,
      pricingStatus: priced ? .priced : .unpriced, source: source, walletLabel: label,
      unlocksAt: unlocksAt)
  }

  private static func kraken(_ symbol: String, amount: Double, day: Int) -> TrackedAsset {
    let unit = price(symbol, day: day)
    return TrackedAsset(
      id: "\(krakenID.uuidString)-kraken-\(symbol)", address: "Kraken", chainId: "kraken",
      chainName: "Kraken", family: .exchange, symbol: symbol, name: symbol, amount: amount,
      priceUsd: unit, valueUsd: unit * amount, pricingStatus: .priced, source: .exchange,
      walletLabel: "Kraken", exchangeId: krakenID, exchangeProvider: .kraken)
  }

  static func holdings(day: Int, includeUnpriced: Bool = false) -> [TrackedAsset] {
    let unstaked = day >= unstakeDay
    let baseEth = day >= dayCount - 1 ? 1.0094 : 1.0
    var holdings: [TrackedAsset] = [
      wallet(
        "BTC", amount: 0.362, day: day, family: .bitcoin, chainId: "bitcoin",
        chainName: "Bitcoin", address: bitcoinAddress, label: "Cold storage"),
      kraken("BTC", amount: 0.05, day: day),
      wallet(
        "ETH", amount: 2.6, day: day, family: .evm, chainId: "ethereum", chainName: "Ethereum",
        address: evmAddress, label: "Main"),
      wallet(
        "ETH", amount: baseEth, day: day, family: .evm, chainId: "base", chainName: "Base",
        address: evmAddress, label: "Main"),
      kraken("ETH", amount: 0.5, day: day),
      wallet(
        "LINK", amount: 120, day: day, source: .erc20, family: .evm, chainId: "ethereum",
        chainName: "Ethereum", address: evmAddress, label: "Main"),
      wallet(
        "ARB", amount: 900, day: day, source: .erc20, family: .evm, chainId: "arbitrum",
        chainName: "Arbitrum One", address: evmAddress, label: "Main"),
      wallet(
        "SOL", amount: 12.5, day: day, family: .solana, chainId: "solana", chainName: "Solana",
        address: solanaAddress, label: "Phantom"),
      wallet(
        "SOL", amount: 26, day: day, source: .staked, family: .solana, chainId: "solana",
        chainName: "Solana", address: solanaAddress, label: "Phantom"),
      wallet(
        "ATOM", amount: 4.2, day: day, family: .cosmos, chainId: "cosmoshub",
        chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
      wallet(
        "ATOM", amount: unstaked ? 280 : 304.79, day: day, source: .staked, family: .cosmos,
        chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr"),
      wallet(
        "ATOM", amount: min(0.2 + 0.025 * Double(day), 1.21), day: day, source: .rewards,
        family: .cosmos, chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress,
        label: "Keplr"),
      kraken("USDC", amount: 920.05, day: day),
      kraken("DOGE", amount: 2_400, day: day),
    ]
    if unstaked {
      holdings.append(
        wallet(
          "ATOM", amount: 24.79, day: day, source: .unbonding, family: .cosmos,
          chainId: "cosmoshub", chainName: "Cosmos Hub", address: cosmosAddress, label: "Keplr",
          unlocksAt: unlockDate))
    }
    if day >= sourceChangeDay {
      holdings.append(
        wallet(
          "ETH", amount: 1.5, day: day, family: .evm, chainId: "ethereum",
          chainName: "Ethereum", address: savingsAddress, label: "Savings"))
      holdings.append(
        wallet(
          "USDC", amount: 500, day: day, source: .erc20, family: .evm, chainId: "ethereum",
          chainName: "Ethereum", address: savingsAddress, label: "Savings"))
    }
    if includeUnpriced {
      holdings.append(
        wallet(
          "MEME", amount: 1_000_000, day: day, source: .erc20, family: .evm,
          chainId: "ethereum", chainName: "Ethereum", address: evmAddress, label: "Main",
          priced: false))
    }
    return holdings
  }

  // MARK: Runs

  /// Days with a scan, oldest first (day index, hour of the scan).
  static var scanSchedule: [(day: Int, hour: Int)] {
    var schedule: [(Int, Int)] = []
    for day in 0..<dayCount where day % 7 != 3 {
      schedule.append((day, 0))
      if day % 10 == 0 && day > 0 { schedule.append((day, 10)) }
    }
    return schedule
  }

  static func run(day: Int, hour: Int = 0, includeUnpriced: Bool = false) -> ScanRunRecord {
    let holdings = holdings(day: day, includeUnpriced: includeUnpriced)
    let id = UUID(
      uuidString: String(format: "00000000-0000-4000-8000-%012d", day * 100 + hour))!
    return ScanRunRecord(
      id: id, generatedAt: scanDate(day: day, hour: hour),
      totalUsd: holdings.filter { $0.pricingStatus == .priced }.map(\.valueUsd).reduce(0, +),
      inputCount: day >= sourceChangeDay ? 6 : 5, holdings: holdings)
  }

  static func runs(includeUnpriced: Bool = false) -> [ScanRunRecord] {
    scanSchedule.map { run(day: $0.day, hour: $0.hour, includeUnpriced: includeUnpriced) }
  }

  /// The latest scan's holdings.
  static var latestHoldings: [TrackedAsset] { holdings(day: dayCount - 1) }

  /// Holdings of the latest scan, plus a run list, as a chart input.
  static func input(
    grouping: PortfolioGrouping = .asset,
    coinKey: String? = nil,
    density: PortfolioChartDensity = .full,
    timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current,
    runs: [ScanRunRecord]? = nil,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) -> PortfolioChartInput {
    let allRuns = runs ?? self.runs()
    let latest = allRuns.last?.holdings ?? latestHoldings
    let holdings =
      coinKey.map { key in latest.filter { CoinIdentity.key(for: $0) == key } } ?? latest
    return PortfolioChartInput(
      holdings: holdings, runs: allRuns, grouping: grouping, coinKey: coinKey, sourceContext: nil,
      timeZone: timeZone, density: density, onSelect: onSelect)
  }
}
