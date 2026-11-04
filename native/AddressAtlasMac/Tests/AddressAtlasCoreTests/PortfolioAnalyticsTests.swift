import XCTest

@testable import AddressAtlasCore

final class PortfolioAnalyticsTests: XCTestCase {
  private typealias Fixture = PortfolioFixture
  private let accuracy = 1e-9

  private var holdings: [TrackedAsset] { Fixture.portfolio() }

  // MARK: Identity, state, kind

  func testEverySourceMapsToOneState() {
    let expected: [AssetSource: HoldingState] = [
      .native: .liquid, .erc20: .liquid, .spl: .liquid, .trc20: .liquid, .issued: .liquid,
      .staked: .staked, .unbonding: .unbonding, .rewards: .rewards, .exchange: .onExchange,
    ]
    XCTAssertEqual(Set(expected.keys).count, 9)
    for (source, state) in expected { XCTAssertEqual(HoldingState(source: source), state) }
    // Manual holdings share the exchange presentation.
    XCTAssertEqual(HoldingState(Fixture.manual("ETH", amount: 1, price: 1)), .onExchange)
    XCTAssertEqual(
      HoldingState.allCases, [.liquid, .staked, .unbonding, .rewards, .onExchange])
  }

  func testCoinIdentityIsTheSymbolWithBridgedStablecoinsFoldedAndWrappedAssetsKeptApart() {
    XCTAssertEqual(CoinIdentity.key(forSymbol: " eth "), "ETH")
    XCTAssertEqual(CoinIdentity.key(forSymbol: "stETH"), "STETH")
    XCTAssertEqual(CoinIdentity.key(forSymbol: "USDC.e"), "USDC")
    XCTAssertEqual(CoinIdentity.key(forSymbol: "usdt0"), "USDT")
    XCTAssertEqual(CoinIdentity.key(forSymbol: "USDT.e"), "USDT")
    XCTAssertEqual(CoinIdentity.key(forSymbol: "DAI.e"), "DAI")
    for separate in ["WETH", "WBTC", "cbBTC", "BTC.b", "WETH.e", "LINK.e"] {
      XCTAssertEqual(CoinIdentity.key(forSymbol: separate), separate.uppercased(), separate)
    }
    XCTAssertEqual(CoinIdentity.key(forSymbol: "   "), "?")
  }

  func testKindIsNativeTokenOrStablecoinWithExchangeRowsClassifiedBySymbol() {
    func kind(_ symbol: String, source: AssetSource, family: ChainFamily = .evm) -> HoldingKind {
      HoldingKind(
        TrackedAsset(
          id: "x", address: Fixture.evmAddress, chainId: "c", chainName: "C", family: family,
          symbol: symbol, name: symbol, amount: 1, priceUsd: 1, valueUsd: 1, source: source))
    }
    // A chain's own coin is native in every state, even if it is pegged.
    for source in [AssetSource.native, .staked, .unbonding, .rewards] {
      XCTAssertEqual(kind("ATOM", source: source), .native, source.rawValue)
    }
    XCTAssertEqual(kind("XDAI", source: .native), .native)
    // Contract tokens: stablecoins by the documented list, the rest tokens.
    for symbol in ["USDC", "usdt", "DAI", "USDe", "PYUSD", "FDUSD", "TUSD", "USDS", "USDC.e", "USDT0"] {
      XCTAssertEqual(kind(symbol, source: .erc20), .stablecoin, symbol)
    }
    XCTAssertEqual(kind("LINK", source: .erc20), .token)
    XCTAssertEqual(kind("WETH", source: .erc20), .token)
    XCTAssertEqual(kind("JUP", source: .spl), .token)
    XCTAssertEqual(kind("USDT", source: .trc20), .stablecoin)
    XCTAssertEqual(kind("RLUSD", source: .issued), .stablecoin)
    // Exchange rows carry no contract: registry coins and well-known layer-1
    // coins are native, listed stablecoins are stablecoins, the rest tokens.
    for symbol in ["BTC", "ETH", "SOL", "ATOM", "XRP", "DOGE", "ADA", "DOT", "LTC"] {
      XCTAssertEqual(kind(symbol, source: .exchange, family: .exchange), .native, symbol)
    }
    XCTAssertEqual(kind("USDC", source: .exchange, family: .exchange), .stablecoin)
    XCTAssertEqual(kind("LINK", source: .exchange, family: .exchange), .token)
    XCTAssertEqual(kind("PEPE", source: .exchange, family: .exchange), .token)
  }

  func testCustodyTellsWalletsFromExchangesAndManualEntries() {
    let all = holdings + [Fixture.manual("ETH", amount: 1, price: 3_000)]
    let counts = Dictionary(grouping: all, by: { HoldingCustody($0) }).mapValues(\.count)
    XCTAssertEqual(counts[.wallet], 9)
    XCTAssertEqual(counts[.exchange], 3)
    XCTAssertEqual(counts[.manual], 1)
  }

  // MARK: Breakdown

  func testBreakdownByAssetSumsEverythingAndSortsByValue() {
    let breakdown = PortfolioAnalytics.breakdown(holdings, by: .asset)

    XCTAssertEqual(breakdown.totalValueUsd, 51_525, accuracy: accuracy)
    XCTAssertEqual(
      breakdown.slices.map(\.key), ["BTC", "ETH", "SOL", "ATOM", "USDC"])
    XCTAssertEqual(
      breakdown.slices.map(\.valueUsd), [36_000, 10_500, 3_000, 1_125, 900])
    XCTAssertEqual(breakdown.slices.map(\.holdingCount), [2, 3, 2, 4, 1])
    XCTAssertEqual(breakdown.slices.map(\.share).reduce(0, +), 1, accuracy: accuracy)
    XCTAssertEqual(breakdown.slices[0].share, 36_000 / 51_525, accuracy: accuracy)
    XCTAssertEqual(breakdown.slices[0].shareOfParent, breakdown.slices[0].share)
    XCTAssertEqual(breakdown.slices[0].label, "BTC")
    XCTAssertTrue(breakdown.slices.allSatisfy { $0.children.isEmpty })
    XCTAssertTrue(breakdown.unpriced.isEmpty)
    // Holding ids come back largest first so a view can drill down.
    XCTAssertEqual(breakdown.slices[1].holdingIDs.count, 3)
    XCTAssertEqual(
      breakdown.slices[1].holdingIDs.first,
      "\(Fixture.evmAddress)-ethereum-ETH-native")
  }

  func testBreakdownByStateKindNetworkAndSourceMatchTheMockupGroupings() {
    func values(_ grouping: PortfolioGrouping) -> [String: Double] {
      Dictionary(
        uniqueKeysWithValues: PortfolioAnalytics.breakdown(holdings, by: grouping).slices.map {
          ($0.label, $0.valueUsd)
        })
    }
    XCTAssertEqual(
      values(.state),
      ["Liquid": 40_020, "Staked": 3_000, "Unbonding": 100, "Rewards": 5, "On exchange": 8_400])
    XCTAssertEqual(values(.kind), ["Native": 50_625, "Stablecoin": 900])
    // Exchanges are networks of their own; Base and Ethereum stay apart.
    XCTAssertEqual(
      values(.network),
      [
        "Bitcoin": 30_000, "Ethereum": 6_000, "Base": 3_000, "Solana": 3_000,
        "Cosmos Hub": 1_125, "Kraken": 8_400,
      ])
    // One EVM address on two networks is one wallet.
    XCTAssertEqual(
      values(.source),
      ["Cold storage": 30_000, "Main": 9_000, "Phantom": 3_000, "Keplr": 1_125, "Kraken": 8_400])
    for grouping in PortfolioGrouping.allCases {
      let breakdown = PortfolioAnalytics.breakdown(holdings, by: grouping)
      XCTAssertEqual(breakdown.slices.map(\.share).reduce(0, +), 1, accuracy: accuracy)
      XCTAssertEqual(breakdown.slices.map(\.holdingCount).reduce(0, +), holdings.count)
    }
  }

  func testNestedBreakdownSplitsEachSliceByTheSecondGroupingForTheTwoRingChart() throws {
    let breakdown = PortfolioAnalytics.breakdown(holdings, by: .asset, then: .state)

    let eth = try XCTUnwrap(breakdown.slices.first { $0.key == "ETH" })
    XCTAssertEqual(eth.children.map(\.key), ["liquid", "onExchange"])
    XCTAssertEqual(eth.children.map(\.valueUsd), [9_000, 1_500])
    XCTAssertEqual(eth.children.map(\.id), ["ETH>liquid", "ETH>onExchange"])
    XCTAssertEqual(eth.children[0].share, 9_000 / 51_525, accuracy: accuracy)
    XCTAssertEqual(eth.children[0].shareOfParent, 9_000 / 10_500, accuracy: accuracy)
    XCTAssertEqual(eth.children.map(\.shareOfParent).reduce(0, +), 1, accuracy: accuracy)
    XCTAssertEqual(eth.children[0].grouping, .state)

    let atom = try XCTUnwrap(breakdown.slices.first { $0.key == "ATOM" })
    XCTAssertEqual(atom.children.map(\.key), ["staked", "unbonding", "liquid", "rewards"])
    XCTAssertEqual(atom.children.map(\.valueUsd), [1_000, 100, 20, 5])
    // Children partition their parent exactly.
    for slice in breakdown.slices {
      XCTAssertEqual(slice.children.map(\.valueUsd).reduce(0, +), slice.valueUsd, accuracy: accuracy)
      XCTAssertEqual(slice.children.map(\.holdingCount).reduce(0, +), slice.holdingCount)
    }
    // Child ids are unique across the whole tree, so a flattened sunburst can
    // key on them.
    let ids = breakdown.slices.flatMap { [$0.id] + $0.children.map(\.id) }
    XCTAssertEqual(Set(ids).count, ids.count)
  }

  func testUnpricedHoldingsNeverEnterValueMathAndAreReturnedSeparately() {
    let pepe = Fixture.wallet(
      "PEPE", amount: 1_000_000, price: nil, source: .erc20, family: .evm, chainId: "ethereum",
      chainName: "Ethereum", address: Fixture.evmAddress, label: "Main")
    var unavailable = Fixture.wallet(
      "WILD", amount: 5, price: 1, family: .evm, chainId: "base", chainName: "Base",
      address: Fixture.evmAddress, label: "Main")
    unavailable.pricingStatus = .valuationUnavailable
    unavailable.valueUsd = 0

    let breakdown = PortfolioAnalytics.breakdown(
      holdings + [pepe, unavailable], by: .asset, then: .network)

    XCTAssertEqual(breakdown.totalValueUsd, 51_525, accuracy: accuracy)
    XCTAssertEqual(breakdown.unpriced.map(\.symbol), ["PEPE", "WILD"])
    XCTAssertFalse(breakdown.slices.contains { $0.key == "PEPE" || $0.key == "WILD" })
    XCTAssertEqual(breakdown.slices.map(\.share).reduce(0, +), 1, accuracy: accuracy)
    // The coin summary still counts the unpriced amount and says it is unpriced.
    let summary = PortfolioAnalytics.coinSummary(holdings + [pepe], coin: "pepe")
    XCTAssertEqual(summary?.totalAmount, 1_000_000)
    XCTAssertEqual(summary?.pricedAmount, 0)
    XCTAssertNil(summary?.priceUsd)
    XCTAssertEqual(summary?.valueUsd, 0)
    XCTAssertEqual(summary?.unpricedHoldingCount, 1)
  }

  func testEmptyAndAllUnpricedPortfoliosHaveNoSlicesAndNoDivisionByZero() {
    let unpriced = Fixture.kraken("PEPE", amount: 5, price: nil)
    for input in [[], [unpriced]] as [[TrackedAsset]] {
      for grouping in PortfolioGrouping.allCases {
        let breakdown = PortfolioAnalytics.breakdown(input, by: grouping, then: .state)
        XCTAssertEqual(breakdown.totalValueUsd, 0)
        XCTAssertTrue(breakdown.slices.isEmpty)
        XCTAssertEqual(breakdown.unpriced.count, input.count)
      }
      let concentration = PortfolioAnalytics.concentration(input)
      XCTAssertEqual(concentration.herfindahlIndex, 0)
      XCTAssertEqual(concentration.effectiveHoldings, 0)
      XCTAssertNil(concentration.level)
      XCTAssertEqual(PortfolioAnalytics.flowGraph(input).edges, [])
    }
  }

  func testAPricedHoldingWorthZeroKeepsItsSliceWithAZeroShare() {
    let free = Fixture.kraken("FREE", amount: 10, price: 0)

    let slices = PortfolioAnalytics.breakdown(holdings + [free], by: .asset).slices

    XCTAssertEqual(slices.last?.key, "FREE")
    XCTAssertEqual(slices.last?.valueUsd, 0)
    XCTAssertEqual(slices.last?.share, 0)
  }

  func testNetworkGroupingKeepsManualVenuesApart() {
    let manual = Fixture.manual("ETH", amount: 1, price: 3_000, venue: "Ledger")
    var other = Fixture.manual("BTC", amount: 1, price: 60_000, venue: "Trezor")
    other.id = "manual-22222222-2222-4222-8222-222222222222"

    let slices = PortfolioAnalytics.breakdown([manual, other], by: .network).slices

    XCTAssertEqual(Set(slices.map(\.label)), ["Ledger", "Trezor"])
    XCTAssertEqual(
      Set(PortfolioAnalytics.breakdown([manual, other], by: .source).slices.map(\.key)),
      [
        "manual:11111111-2222-4333-8444-555555555555",
        "manual:22222222-2222-4222-8222-222222222222",
      ])
  }

  func testDustFilterIsAppliedOnlyWhenTheCallerPassesIt() {
    let unpriced = Fixture.kraken("PEPE", amount: 5, price: nil)
    let all = holdings + [unpriced]

    XCTAssertEqual(PortfolioHoldingFilter().apply(all).count, all.count)
    XCTAssertEqual(PortfolioHoldingFilter(dustThresholdUsd: 0).apply(all).count, all.count)
    let filtered = PortfolioHoldingFilter(dustThresholdUsd: 100).apply(all)
    // ATOM liquid ($20) and rewards ($5) are dust; $100 itself is kept, and an
    // unpriced holding is unknown, not small.
    XCTAssertEqual(filtered.count, all.count - 2)
    XCTAssertTrue(filtered.contains { $0.symbol == "PEPE" })
    XCTAssertFalse(filtered.contains { $0.source == .rewards })
    XCTAssertEqual(
      PortfolioAnalytics.breakdown(filtered, by: .asset).totalValueUsd, 51_500, accuracy: accuracy)
  }

  // MARK: Coin summaries

  func testCoinSummarySplitsAnEtherAcrossNetworksAndAnExchange() throws {
    let eth = try XCTUnwrap(PortfolioAnalytics.coinSummary(holdings, coin: "eth"))

    XCTAssertEqual(eth.id, "ETH")
    XCTAssertEqual(eth.symbol, "ETH")
    XCTAssertEqual(eth.totalAmount, 3.5)
    XCTAssertEqual(eth.pricedAmount, 3.5)
    XCTAssertEqual(eth.valueUsd, 10_500, accuracy: accuracy)
    XCTAssertEqual(try XCTUnwrap(eth.priceUsd), 3_000, accuracy: accuracy)
    XCTAssertEqual(eth.holdingCount, 3)
    XCTAssertEqual(eth.unpricedHoldingCount, 0)

    XCTAssertEqual(eth.states.map(\.state), [.liquid, .onExchange])
    XCTAssertEqual(eth.states.map(\.amount), [3, 0.5])
    XCTAssertEqual(eth.states.map(\.share), [9_000 / 10_500, 1_500 / 10_500])

    XCTAssertEqual(eth.locations.map(\.networkLabel), ["Ethereum", "Base", "Kraken"])
    XCTAssertEqual(eth.locations.map(\.sourceLabel), ["Main", "Main", "Kraken"])
    XCTAssertEqual(eth.locations.map(\.amount), [2, 1, 0.5])
    XCTAssertEqual(eth.locations.map(\.states), [[.liquid], [.liquid], [.onExchange]])
    XCTAssertEqual(eth.locations.map(\.share).reduce(0, +), 1, accuracy: accuracy)

    XCTAssertEqual(eth.custody.walletAmount, 3)
    XCTAssertEqual(eth.custody.exchangeAmount, 0.5)
    XCTAssertEqual(eth.custody.manualAmount, 0)
    XCTAssertEqual(try XCTUnwrap(eth.custody.selfCustodyShare), 3 / 3.5, accuracy: accuracy)
    XCTAssertTrue(eth.unlocks.isEmpty)
  }

  func testCoinSummaryShowsEveryStateOfAStakedCoinWithTheUnlockTime() throws {
    let atom = try XCTUnwrap(PortfolioAnalytics.coinSummary(holdings, coin: "ATOM"))

    XCTAssertEqual(atom.totalAmount, 225)
    XCTAssertEqual(atom.valueUsd, 1_125, accuracy: accuracy)
    XCTAssertEqual(atom.states.map(\.state), [.liquid, .staked, .unbonding, .rewards])
    XCTAssertEqual(atom.states.map(\.amount), [4, 200, 20, 1])
    XCTAssertEqual(atom.states.map(\.valueUsd), [20, 1_000, 100, 5])
    XCTAssertEqual(atom.states.map(\.earliestUnlock), [nil, nil, Fixture.unlock, nil])
    XCTAssertEqual(
      atom.unlocks, [CoinUnlock(date: Fixture.unlock, amount: 20, valueUsd: 100)])
    // Staking from your own wallet is still self-custody.
    XCTAssertEqual(atom.custody.selfCustodyShare, 1)
    XCTAssertEqual(atom.locations.count, 1)
    XCTAssertEqual(atom.locations[0].states, [.liquid, .staked, .unbonding, .rewards])
  }

  func testUnlocksAreSortedSoonestFirstWithUndatedLastAndEarliestPerState() throws {
    func unbonding(_ amount: Double, unlocksAt: Date?, suffix: String) -> TrackedAsset {
      Fixture.wallet(
        "ATOM", amount: amount, price: 5, source: .unbonding, family: .cosmos,
        chainId: "cosmoshub", chainName: "Cosmos Hub", address: Fixture.cosmosAddress,
        label: "Keplr", unlocksAt: unlocksAt, idSuffix: suffix)
    }
    let early = Fixture.date("2026-11-10T00:00:00Z")
    let late = Fixture.date("2026-11-20T00:00:00Z")
    let input = [
      unbonding(3, unlocksAt: late, suffix: "b"),
      unbonding(1, unlocksAt: nil, suffix: "undated"),
      unbonding(2, unlocksAt: early, suffix: "a"),
      unbonding(4, unlocksAt: early, suffix: "c"),
    ]

    let atom = try XCTUnwrap(PortfolioAnalytics.coinSummary(input, coin: "ATOM"))

    XCTAssertEqual(
      atom.unlocks,
      [
        CoinUnlock(date: early, amount: 6, valueUsd: 30),
        CoinUnlock(date: late, amount: 3, valueUsd: 15),
        CoinUnlock(date: nil, amount: 1, valueUsd: 5),
      ])
    XCTAssertEqual(atom.states.first?.earliestUnlock, early)
  }

  func testSelfCustodyShareCountsManualEntriesInTheDenominatorOnly() throws {
    let bitcoin = try XCTUnwrap(PortfolioAnalytics.coinSummary(holdings, coin: "BTC"))
    XCTAssertEqual(try XCTUnwrap(bitcoin.custody.selfCustodyShare), 0.5 / 0.6, accuracy: accuracy)
    XCTAssertEqual(bitcoin.custody.walletValueUsd, 30_000, accuracy: accuracy)
    XCTAssertEqual(bitcoin.custody.exchangeValueUsd, 6_000, accuracy: accuracy)

    let withManual = holdings + [Fixture.manual("BTC", amount: 0.4, price: 60_000)]
    let summary = try XCTUnwrap(PortfolioAnalytics.coinSummary(withManual, coin: "BTC"))
    XCTAssertEqual(summary.custody.manualAmount, 0.4)
    XCTAssertEqual(try XCTUnwrap(summary.custody.selfCustodyShare), 0.5 / 1.0, accuracy: accuracy)
  }

  func testStablecoinVariantsAcrossNetworksAreOneCoinWithAnAmountWeightedPrice() throws {
    let usdc = Fixture.wallet(
      "USDC", amount: 100, price: 1, source: .erc20, family: .evm, chainId: "ethereum",
      chainName: "Ethereum", address: Fixture.evmAddress, label: "Main")
    let bridged = Fixture.wallet(
      "USDC.e", amount: 300, price: 1.002, source: .erc20, family: .evm, chainId: "arbitrum",
      chainName: "Arbitrum One", address: Fixture.evmAddress, label: "Main")

    let coins = PortfolioAnalytics.coinSummaries([usdc, bridged])

    XCTAssertEqual(coins.count, 1)
    XCTAssertEqual(coins[0].id, "USDC")
    XCTAssertEqual(coins[0].totalAmount, 400)
    XCTAssertEqual(try XCTUnwrap(coins[0].priceUsd), (100 + 300 * 1.002) / 400, accuracy: accuracy)
    XCTAssertEqual(coins[0].locations.count, 2)
  }

  func testCoinSummariesListEveryCoinLargestFirstAndUnknownCoinsAreNil() {
    let summaries = PortfolioAnalytics.coinSummaries(holdings)

    XCTAssertEqual(summaries.map(\.id), ["BTC", "ETH", "SOL", "ATOM", "USDC"])
    XCTAssertNil(PortfolioAnalytics.coinSummary(holdings, coin: "NOPE"))
  }

  // MARK: Flow

  func testFlowGraphRunsFromSourceToCoinToStateAndConservesValue() throws {
    let flow = PortfolioAnalytics.flowGraph(holdings)

    XCTAssertEqual(flow.totalValueUsd, 51_525, accuracy: accuracy)
    func column(_ column: FlowColumn) -> [FlowNode] { flow.nodes.filter { $0.column == column } }
    XCTAssertEqual(
      column(.source).map(\.label), ["Cold storage", "Main", "Kraken", "Phantom", "Keplr"])
    XCTAssertEqual(column(.coin).map(\.label), ["BTC", "ETH", "SOL", "ATOM", "USDC"])
    XCTAssertEqual(
      column(.state).map(\.label), ["Liquid", "On exchange", "Staked", "Unbonding", "Rewards"])
    for node in column(.coin) + column(.source) + column(.state) {
      XCTAssertTrue(node.id.hasPrefix(["source", "coin", "state"][node.column.rawValue] + ":"))
    }
    // Every column carries the whole portfolio.
    for flowColumn in FlowColumn.allCases {
      XCTAssertEqual(
        column(flowColumn).map(\.valueUsd).reduce(0, +), 51_525, accuracy: accuracy)
    }
    // Every coin node's inflow equals its outflow.
    for coin in column(.coin) {
      let inflow = flow.edges.filter { $0.to == coin.id }.map(\.valueUsd).reduce(0, +)
      let outflow = flow.edges.filter { $0.from == coin.id }.map(\.valueUsd).reduce(0, +)
      XCTAssertEqual(inflow, coin.valueUsd, accuracy: accuracy, coin.label)
      XCTAssertEqual(outflow, coin.valueUsd, accuracy: accuracy, coin.label)
    }
    // Specific edges, e.g. ETH reaches liquid from Main and on exchange from Kraken.
    func edge(_ from: String, _ to: String) -> Double? {
      flow.edges.first { $0.from == from && $0.to == to }?.valueUsd
    }
    let main = try XCTUnwrap(
      column(.source).first { $0.label == "Main" }).id
    XCTAssertEqual(edge(main, "coin:ETH"), 9_000)
    XCTAssertEqual(edge("coin:ETH", "state:liquid"), 9_000)
    XCTAssertEqual(edge("coin:ETH", "state:onExchange"), 1_500)
    XCTAssertEqual(edge("coin:ATOM", "state:unbonding"), 100)
    XCTAssertNil(edge("coin:ETH", "state:staked"))
    // Source -> coin edges precede coin -> state edges.
    let firstStateEdge = flow.edges.firstIndex { $0.from.hasPrefix("coin:") } ?? 0
    XCTAssertTrue(flow.edges[..<firstStateEdge].allSatisfy { $0.from.hasPrefix("source:") })
  }

  // MARK: Concentration

  private func equalCoins(_ count: Int) -> [TrackedAsset] {
    (0..<count).map {
      Fixture.kraken("C\($0)", amount: 1, price: 100)
    }
  }

  func testConcentrationMeasuresTopSharesHerfindahlAndEffectiveHoldings() {
    let single = PortfolioAnalytics.concentration(equalCoins(1))
    XCTAssertEqual(single.herfindahlIndex, 1, accuracy: accuracy)
    XCTAssertEqual(single.effectiveHoldings, 1, accuracy: accuracy)
    XCTAssertEqual(single.topShare, 1)
    XCTAssertEqual(single.level, .concentrated)

    let two = PortfolioAnalytics.concentration(equalCoins(2))
    XCTAssertEqual(two.herfindahlIndex, 0.5, accuracy: accuracy)
    XCTAssertEqual(two.effectiveHoldings, 2, accuracy: accuracy)
    XCTAssertEqual(two.topShare, 0.5, accuracy: accuracy)
    XCTAssertEqual(two.topThreeShare, 1, accuracy: accuracy)

    let five = PortfolioAnalytics.concentration(equalCoins(5))
    XCTAssertEqual(five.herfindahlIndex, 0.2, accuracy: accuracy)
    XCTAssertEqual(five.effectiveHoldings, 5, accuracy: accuracy)
    XCTAssertEqual(five.topThreeShare, 0.6, accuracy: accuracy)
    XCTAssertEqual(five.level, .moderate)
    XCTAssertEqual(five.groupCount, 5)

    let ten = PortfolioAnalytics.concentration(equalCoins(10))
    XCTAssertEqual(ten.herfindahlIndex, 0.1, accuracy: accuracy)
    XCTAssertEqual(ten.level, .diversified)

    XCTAssertEqual(PortfolioAnalytics.concentration(equalCoins(4)).level, .concentrated)
    XCTAssertEqual(ConcentrationLevel(herfindahlIndex: 0.1499), .diversified)
    XCTAssertEqual(ConcentrationLevel(herfindahlIndex: 0.15), .moderate)
    XCTAssertEqual(ConcentrationLevel(herfindahlIndex: 0.25), .concentrated)
  }

  func testConcentrationOfTheSamplePortfolioFollowsFromItsShares() throws {
    let concentration = PortfolioAnalytics.concentration(holdings)

    let shares = [36_000, 10_500, 3_000, 1_125, 900].map { Double($0) / 51_525 }
    XCTAssertEqual(concentration.topShare, shares[0], accuracy: accuracy)
    XCTAssertEqual(concentration.topThreeShare, shares[0] + shares[1] + shares[2], accuracy: accuracy)
    let hhi = shares.map { $0 * $0 }.reduce(0, +)
    XCTAssertEqual(concentration.herfindahlIndex, hhi, accuracy: accuracy)
    XCTAssertEqual(concentration.effectiveHoldings, 1 / hhi, accuracy: accuracy)
    XCTAssertEqual(concentration.leaders.map(\.label), ["BTC", "ETH", "SOL"])
    XCTAssertEqual(concentration.level, .concentrated)
    XCTAssertEqual(concentration.groupCount, 5)
    // The same measure by another dimension.
    let byState = PortfolioAnalytics.concentration(holdings, by: .state)
    XCTAssertEqual(byState.grouping, .state)
    XCTAssertEqual(byState.leaders.first?.label, "Liquid")
  }

  func testUnpricedHoldingsDoNotDiluteConcentration() {
    let withUnpriced = equalCoins(2) + [Fixture.kraken("PEPE", amount: 1_000, price: nil)]
    XCTAssertEqual(
      PortfolioAnalytics.concentration(withUnpriced).herfindahlIndex, 0.5, accuracy: accuracy)
  }

  // MARK: Determinism

  func testResultsDoNotDependOnTheOrderHoldingsArriveIn() {
    var generator = SeededGenerator(seed: 42)
    var all = holdings + [
      Fixture.wallet(
        "USDC", amount: 0.1, price: 0.3, source: .erc20, family: .evm, chainId: "base",
        chainName: "Base", address: Fixture.evmAddress, label: "Main"),
      Fixture.kraken("PEPE", amount: 4, price: nil),
    ]
    let reference = Snapshot(all)
    for _ in 0..<20 {
      all.shuffle(using: &generator)
      XCTAssertEqual(Snapshot(all), reference)
    }
  }

  private struct Snapshot: Equatable {
    var breakdowns: [PortfolioBreakdown]
    var coins: [CoinSummary]
    var flow: FlowGraph
    var concentration: Concentration

    init(_ holdings: [TrackedAsset]) {
      breakdowns = PortfolioGrouping.allCases.flatMap { grouping in
        PortfolioGrouping.allCases.map {
          PortfolioAnalytics.breakdown(holdings, by: grouping, then: $0)
        }
      }
      coins = PortfolioAnalytics.coinSummaries(holdings)
      flow = PortfolioAnalytics.flowGraph(holdings)
      concentration = PortfolioAnalytics.concentration(holdings)
    }
  }
}

/// A small deterministic generator so shuffles are reproducible.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
