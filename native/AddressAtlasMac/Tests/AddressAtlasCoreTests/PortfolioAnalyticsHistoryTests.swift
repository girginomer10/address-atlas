import XCTest

@testable import AddressAtlasCore

final class PortfolioAnalyticsHistoryTests: XCTestCase {
  private typealias Fixture = PortfolioFixture
  private let accuracy = 1e-9

  private func evmToken(
    _ symbol: String, amount: Double, price: Double?, chainId: String = "ethereum",
    chainName: String = "Ethereum"
  ) -> TrackedAsset {
    Fixture.wallet(
      symbol, amount: amount, price: price, source: .erc20, family: .evm, chainId: chainId,
      chainName: chainName, address: Fixture.evmAddress, label: "Main")
  }

  private func change(_ attribution: ChangeAttribution, _ coin: String) throws -> CoinChange {
    try XCTUnwrap(attribution.coins.first { $0.id == coin }, "no change for \(coin)")
  }

  // MARK: Change attribution

  func testPriceAndAmountEffectsFollowTheDocumentedFormulas() throws {
    // Older: 3.4 ETH at $3,000. Newer: 3.5 ETH at $3,200 (0.1 received on Base).
    let older = Fixture.run(
      "2026-11-03T09:00:00Z",
      Fixture.portfolio(prices: .init(eth: 3_000), baseEth: 0.9))
    let newer = Fixture.run(
      "2026-11-04T09:00:00Z",
      Fixture.portfolio(prices: .init(eth: 3_200), baseEth: 1.0))

    let attribution = PortfolioAnalytics.attribution(from: older, to: newer)
    let eth = try change(attribution, "ETH")

    XCTAssertEqual(eth.status, .changed)
    XCTAssertEqual(eth.olderAmount, 3.4, accuracy: accuracy)
    XCTAssertEqual(eth.newerAmount, 3.5, accuracy: accuracy)
    XCTAssertEqual(try XCTUnwrap(eth.olderPriceUsd), 3_000, accuracy: accuracy)
    XCTAssertEqual(try XCTUnwrap(eth.newerPriceUsd), 3_200, accuracy: accuracy)
    // price effect = old amount * (new price - old price) = 3.4 * 200
    XCTAssertEqual(eth.priceEffectUsd, 680, accuracy: accuracy)
    // amount effect = (new amount - old amount) * new price = 0.1 * 3200
    XCTAssertEqual(eth.amountEffectUsd, 320, accuracy: accuracy)
    XCTAssertEqual(eth.valuationGapUsd, 0)
    XCTAssertEqual(eth.deltaUsd, 11_200 - 10_200, accuracy: accuracy)
    XCTAssertEqual(
      eth.priceEffectUsd + eth.amountEffectUsd + eth.valuationGapUsd, eth.deltaUsd,
      accuracy: accuracy)

    // The received coins are traced to where they arrived.
    XCTAssertEqual(eth.locationChanges.count, 1)
    XCTAssertEqual(eth.locationChanges[0].networkLabel, "Base")
    XCTAssertEqual(eth.locationChanges[0].sourceLabel, "Main")
    XCTAssertEqual(eth.locationChanges[0].deltaAmount, 0.1, accuracy: accuracy)

    XCTAssertFalse(attribution.hasUnpricedHoldings)
    XCTAssertEqual(attribution.olderRunID, older.id)
    XCTAssertEqual(attribution.newerRunID, newer.id)
  }

  func testTheWholePortfolioDeltaIsExactlyExplainedByPriceAmountAndValuationGap() throws {
    var olderHoldings = Fixture.portfolio(prices: .init(btc: 60_000, eth: 3_000, atom: 5))
    var newerHoldings = Fixture.portfolio(
      prices: .init(btc: 61_000, eth: 3_200, sol: 90, atom: 4.5), baseEth: 1.25,
      includeSolana: true)
    // A coin that stops having a price, one that gains one, one bought, one sold.
    olderHoldings += [
      evmToken("LINK", amount: 100, price: 15),
      evmToken("ARB", amount: 50, price: nil),
      evmToken("SOLD", amount: 10, price: 8),
    ]
    newerHoldings += [
      evmToken("LINK", amount: 100, price: nil),
      evmToken("ARB", amount: 50, price: 2),
      evmToken("BOUGHT", amount: 4, price: 25),
    ]
    let older = Fixture.run("2026-11-03T09:00:00Z", olderHoldings)
    let newer = Fixture.run("2026-11-04T09:00:00Z", newerHoldings)

    let attribution = PortfolioAnalytics.attribution(from: older, to: newer)

    XCTAssertEqual(attribution.olderTotalUsd, older.totalUsd, accuracy: accuracy)
    XCTAssertEqual(attribution.newerTotalUsd, PortfolioAnalytics.totalValueUsd(newerHoldings), accuracy: accuracy)
    XCTAssertEqual(
      attribution.totalDeltaUsd, attribution.newerTotalUsd - attribution.olderTotalUsd,
      accuracy: accuracy)
    XCTAssertEqual(
      attribution.priceEffectUsd + attribution.amountEffectUsd + attribution.valuationGapUsd,
      attribution.totalDeltaUsd, accuracy: 1e-6)
    XCTAssertEqual(
      attribution.coins.map(\.deltaUsd).reduce(0, +), attribution.totalDeltaUsd, accuracy: 1e-6)
    for coin in attribution.coins {
      XCTAssertEqual(
        coin.priceEffectUsd + coin.amountEffectUsd + coin.valuationGapUsd, coin.deltaUsd,
        accuracy: 1e-6, coin.id)
    }
    XCTAssertTrue(attribution.hasUnpricedHoldings)

    // Held in both, price lost: the whole change is a valuation gap, not a sale.
    let link = try change(attribution, "LINK")
    XCTAssertEqual(link.status, .changed)
    XCTAssertEqual(link.valuationGapUsd, -1_500, accuracy: accuracy)
    XCTAssertEqual(link.priceEffectUsd, 0)
    XCTAssertEqual(link.amountEffectUsd, 0)
    // Held in both, price gained: likewise.
    let arb = try change(attribution, "ARB")
    XCTAssertEqual(arb.valuationGapUsd, 100, accuracy: accuracy)
    XCTAssertEqual(arb.amountEffectUsd, 0)

    // A coin only in the newer scan is added at its full value; only in the
    // older, removed at its full value; neither has a price effect.
    let bought = try change(attribution, "BOUGHT")
    XCTAssertEqual(bought.status, .added)
    XCTAssertEqual(bought.amountEffectUsd, 100, accuracy: accuracy)
    XCTAssertEqual(bought.priceEffectUsd, 0)
    XCTAssertNil(bought.olderPriceUsd)
    let sold = try change(attribution, "SOLD")
    XCTAssertEqual(sold.status, .removed)
    XCTAssertEqual(sold.amountEffectUsd, -80, accuracy: accuracy)
    XCTAssertEqual(sold.priceEffectUsd, 0)
    XCTAssertNil(sold.newerPriceUsd)
    XCTAssertEqual(Set(attribution.addedCoins.map(\.id)), ["BOUGHT"])
    XCTAssertEqual(Set(attribution.removedCoins.map(\.id)), ["SOLD"])

    // A pure price move has no amount effect (BTC: 0.6 coins, +$1,000).
    let btc = try change(attribution, "BTC")
    XCTAssertEqual(btc.priceEffectUsd, 600, accuracy: accuracy)
    XCTAssertEqual(btc.amountEffectUsd, 0, accuracy: accuracy)
  }

  func testOnlyCoinsThatChangedAreListedLargestMoveFirst() {
    let older = Fixture.run("2026-11-03T09:00:00Z", Fixture.portfolio())
    var newerHoldings = Fixture.portfolio()
    newerHoldings[0].amount = 0.51  // 0.5 -> 0.51 BTC
    newerHoldings[0].valueUsd = 0.51 * 60_000
    let newer = Fixture.run("2026-11-04T09:00:00Z", newerHoldings)

    let attribution = PortfolioAnalytics.attribution(from: older, to: newer)

    XCTAssertEqual(attribution.coins.map(\.id), ["BTC"])
    XCTAssertEqual(attribution.totalDeltaUsd, 600, accuracy: 1e-6)
    XCTAssertEqual(attribution.coins[0].amountEffectUsd, 600, accuracy: 1e-6)
    XCTAssertTrue(
      PortfolioAnalytics.attribution(from: older, to: older).coins.isEmpty)
    XCTAssertEqual(PortfolioAnalytics.attribution(from: older, to: older).totalDeltaUsd, 0)
  }

  func testCoinsAreOrderedByTheSizeOfTheirChangeWhetherUpOrDown() {
    let older = Fixture.run(
      "2026-11-03T09:00:00Z",
      [
        evmToken("AAA", amount: 1, price: 100), evmToken("BBB", amount: 1, price: 100),
        evmToken("CCC", amount: 1, price: 100),
      ])
    let newer = Fixture.run(
      "2026-11-04T09:00:00Z",
      [
        evmToken("AAA", amount: 1, price: 110), evmToken("BBB", amount: 1, price: 40),
        evmToken("CCC", amount: 1, price: 100),
      ])

    let attribution = PortfolioAnalytics.attribution(from: older, to: newer)

    XCTAssertEqual(attribution.coins.map(\.id), ["BBB", "AAA"])
    XCTAssertEqual(attribution.coins.map(\.deltaUsd), [-60, 10])
  }

  func testAttributionFlagsScansThatDidNotReadTheSameSources() {
    let base = Fixture.portfolio()
    let older = Fixture.run("2026-11-03T09:00:00Z", base, inputCount: 3)
    let sameSources = Fixture.run("2026-11-04T09:00:00Z", base, inputCount: 3)
    XCTAssertFalse(PortfolioAnalytics.attribution(from: older, to: sameSources).sourcesDiffer)

    // A different number of saved addresses.
    let moreInputs = Fixture.run("2026-11-04T09:00:00Z", base, inputCount: 4)
    XCTAssertTrue(PortfolioAnalytics.attribution(from: older, to: moreInputs).sourcesDiffer)

    // A second wallet appears.
    let extraWallet = Fixture.wallet(
      "ETH", amount: 1, price: 3_000, family: .evm, chainId: "ethereum", chainName: "Ethereum",
      address: Fixture.secondEvmAddress, label: "Savings")
    let withWallet = Fixture.run("2026-11-04T09:00:00Z", base + [extraWallet], inputCount: 3)
    XCTAssertTrue(PortfolioAnalytics.attribution(from: older, to: withWallet).sourcesDiffer)

    // A manual holding appears or disappears.
    let withManual = Fixture.run(
      "2026-11-04T09:00:00Z", base + [Fixture.manual("ETH", amount: 1, price: 3_000)],
      inputCount: 3)
    XCTAssertTrue(PortfolioAnalytics.attribution(from: older, to: withManual).sourcesDiffer)
    XCTAssertTrue(PortfolioAnalytics.attribution(from: withManual, to: older).sourcesDiffer)
  }

  func testAContextLetsAFundedOrEmptiedWalletCountAsTheSameSources() {
    let base = Fixture.portfolio()
    let savings = Fixture.wallet(
      "ETH", amount: 1, price: 3_000, family: .evm, chainId: "ethereum", chainName: "Ethereum",
      address: Fixture.secondEvmAddress, label: "Savings")
    let savingsKey = "wallet:evm:\(Fixture.secondEvmAddress)"
    let older = Fixture.run("2026-11-03T09:00:00Z", base, inputCount: 3)
    let newer = Fixture.run("2026-11-04T09:00:00Z", base + [savings], inputCount: 3)
    let allKeys = Set(base.compactMap(PortfolioAnalytics.sourceKey(for:)))

    // The wallet existed before the older scan and was empty then: funded since.
    let existing = ScanSourceContext(
      savedSourceKeys: allKeys.union([savingsKey]),
      sourceCreatedAt: [savingsKey: Fixture.date("2026-10-01T00:00:00Z")])
    XCTAssertFalse(
      PortfolioAnalytics.attribution(from: older, to: newer, context: existing).sourcesDiffer)

    // The wallet was added after the older scan: not a market move.
    let added = ScanSourceContext(
      savedSourceKeys: allKeys.union([savingsKey]),
      sourceCreatedAt: [savingsKey: Fixture.date("2026-11-03T12:00:00Z")])
    XCTAssertTrue(
      PortfolioAnalytics.attribution(from: older, to: newer, context: added).sourcesDiffer)

    // A source in the older scan that is gone now.
    let removed = ScanSourceContext(savedSourceKeys: allKeys.subtracting([savingsKey]))
    XCTAssertTrue(
      PortfolioAnalytics.attribution(from: newer, to: older, context: removed).sourcesDiffer)
    // ...but one that is still saved and merely emptied is fine.
    let stillSaved = ScanSourceContext(savedSourceKeys: allKeys.union([savingsKey]))
    XCTAssertFalse(
      PortfolioAnalytics.attribution(from: newer, to: older, context: stillSaved).sourcesDiffer)
  }

  func testSourceContextIsBuiltFromTheVaultDocument() throws {
    var document = VaultDocument()
    let created = Fixture.date("2026-10-01T00:00:00Z")
    document.wallets = [
      WalletRecord(
        label: "Main", address: Fixture.evmAddress, chainKind: .evm, createdAt: created,
        updatedAt: created)
    ]
    document.manualHoldings = [
      ManualHoldingRecord(
        id: Fixture.manualID, label: "Ledger", provider: "Manual", symbol: "ETH", name: "Ether",
        amount: 1, priceUsd: 1, valueUsd: 1, enabled: true),
      ManualHoldingRecord(
        label: "Disabled", provider: "Manual", symbol: "ETH", name: "Ether", amount: 1,
        priceUsd: 1, valueUsd: 1, enabled: false),
    ]

    let context = ScanSourceContext(document: document)

    XCTAssertEqual(
      context.savedSourceKeys,
      [
        "wallet:evm:\(Fixture.evmAddress)",
        "manual:\(Fixture.manualID.uuidString.lowercased())",
      ])
    XCTAssertEqual(context.sourceCreatedAt["wallet:evm:\(Fixture.evmAddress)"], created)
  }

  // MARK: Rank change

  func testRankChangesPairEachCoinsPlaceInTwoScans() throws {
    let older = Fixture.portfolio()  // BTC, ETH, SOL, ATOM, USDC
    var newer = Fixture.portfolio(prices: .init(eth: 3_000, sol: 100, atom: 40, usdc: 1))
    newer.removeAll { $0.symbol == "SOL" }
    newer.append(evmToken("LINK", amount: 100, price: 20))

    let changes = PortfolioAnalytics.rankChanges(from: older, to: newer)

    // Newer ranking: BTC 36,000; ETH 10,500; ATOM 9,000; LINK 2,000; USDC 900.
    XCTAssertEqual(changes.map(\.id), ["BTC", "ETH", "ATOM", "LINK", "USDC", "SOL"])
    XCTAssertEqual(changes.map(\.newerRank), [1, 2, 3, 4, 5, nil])
    XCTAssertEqual(changes.map(\.olderRank), [1, 2, 4, nil, 5, 3])
    XCTAssertEqual(changes.map(\.placesGained), [0, 0, 1, nil, 0, nil])
    let atom = try XCTUnwrap(changes.first { $0.id == "ATOM" })
    XCTAssertEqual(atom.olderValueUsd, 1_125, accuracy: accuracy)
    XCTAssertEqual(atom.newerValueUsd, 9_000, accuracy: accuracy)
    let sol = try XCTUnwrap(changes.first { $0.id == "SOL" })
    XCTAssertEqual(sol.newerValueUsd, 0)
    XCTAssertEqual(sol.olderValueUsd, 3_000, accuracy: accuracy)
  }

  func testRankChangesCanBeLimitedToTheTopOfEitherScan() {
    let older = Fixture.run("2026-11-03T09:00:00Z", Fixture.portfolio())
    var newerHoldings = Fixture.portfolio(prices: .init(atom: 40))
    newerHoldings.removeAll { $0.symbol == "SOL" }
    let newer = Fixture.run("2026-11-04T09:00:00Z", newerHoldings)

    let top3 = PortfolioAnalytics.rankChanges(from: older, to: newer, limit: 3)

    // SOL was third before, ATOM is third now; USDC is outside both.
    XCTAssertEqual(Set(top3.map(\.id)), ["BTC", "ETH", "SOL", "ATOM"])
  }

  func testUnpricedCoinsAreNotRankedAndTiesBreakBySymbol() {
    let older = [
      evmToken("BBB", amount: 1, price: 10), evmToken("AAA", amount: 1, price: 10),
      evmToken("ZZZ", amount: 100, price: nil),
    ]

    let changes = PortfolioAnalytics.rankChanges(from: older, to: older)

    XCTAssertEqual(changes.map(\.id), ["AAA", "BBB"])
    XCTAssertEqual(changes.map(\.newerRank), [1, 2])
  }

  // MARK: Series

  private var threeRuns: [ScanRunRecord] {
    var afterUnstake = Fixture.portfolio()
    // 24 ATOM leave "staked" and enter "unbonding" (amounts only; values follow).
    afterUnstake[6].amount = 176
    afterUnstake[6].valueUsd = 176 * 5
    afterUnstake[7].amount = 44
    afterUnstake[7].valueUsd = 44 * 5
    let first = Fixture.run(
      "2026-11-02T09:00:00Z", Fixture.portfolio(), id: "00000000-0000-4000-8000-000000000001")
    let second = Fixture.run(
      "2026-11-03T09:00:00Z", afterUnstake, id: "00000000-0000-4000-8000-000000000002")
    let third = Fixture.run(
      "2026-11-04T09:00:00Z",
      Fixture.portfolio(prices: .init(eth: 3_200)).filter { $0.symbol != "USDC" },
      id: "00000000-0000-4000-8000-000000000003")
    return [first, second, third]
  }

  func testRunTotalsAreOrderedOldestFirstWhateverOrderTheyAreGivenIn() {
    var runs = threeRuns
    runs.reverse()
    runs[1].holdings.append(evmToken("PEPE", amount: 1, price: nil))

    let totals = PortfolioAnalytics.runTotals(runs)

    XCTAssertEqual(
      totals.map { $0.id.uuidString.lowercased() },
      [
        "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002",
        "00000000-0000-4000-8000-000000000003",
      ])
    XCTAssertEqual(totals[0].totalValueUsd, 51_525, accuracy: accuracy)
    XCTAssertEqual(totals[1].totalValueUsd, 51_525, accuracy: accuracy)
    XCTAssertEqual(totals[2].totalValueUsd, 51_525 - 900 + 3.5 * 200, accuracy: accuracy)
    XCTAssertEqual(totals.map(\.pricedHoldingCount), [12, 12, 11])
    XCTAssertEqual(totals.map(\.unpricedHoldingCount), [0, 1, 0])
    // The unpriced PEPE row is a sixth coin in the second scan.
    XCTAssertEqual(totals.map(\.coinCount), [5, 6, 4])
  }

  func testACoinSeriesCarriesAmountValueAndPricePerScanWithZerosWhereAbsent() {
    let series = PortfolioAnalytics.coinSeries(threeRuns, coin: "usdc")

    XCTAssertEqual(series.map(\.amount), [900, 900, 0])
    XCTAssertEqual(series.map(\.valueUsd), [900, 900, 0])
    XCTAssertEqual(series.map(\.priceUsd), [1, 1, nil])
    let eth = PortfolioAnalytics.coinSeries(threeRuns, coin: "ETH")
    XCTAssertEqual(eth.map(\.amount), [3.5, 3.5, 3.5])
    XCTAssertEqual(eth.map(\.priceUsd), [3_000, 3_000, 3_200])
    XCTAssertEqual(series.map(\.generatedAt), threeRuns.map(\.generatedAt))
  }

  func testStackedSeriesFollowsOneCoinsAmountByStateInCoinsNotDollars() throws {
    let series = PortfolioAnalytics.stackedSeries(
      threeRuns, by: .state, coin: "ATOM", measure: .amount)

    XCTAssertEqual(series.runIDs.count, 3)
    XCTAssertEqual(series.measure, .amount)
    // Layers come largest total first.
    XCTAssertEqual(series.layers.map(\.id), ["staked", "unbonding", "liquid", "rewards"])
    let byID = Dictionary(uniqueKeysWithValues: series.layers.map { ($0.id, $0.values) })
    XCTAssertEqual(byID["staked"], [200, 176, 200])
    XCTAssertEqual(byID["unbonding"], [20, 44, 20])
    XCTAssertEqual(byID["liquid"], [4, 4, 4])
    XCTAssertEqual(byID["rewards"], [1, 1, 1])
    // The unstake moved 24 coins between states without changing the total.
    XCTAssertEqual(series.totals, [225, 225, 225])
    XCTAssertEqual(series.layers.map(\.label), ["Staked", "Unbonding", "Liquid", "Rewards"])
  }

  func testStackedValueSeriesZeroFillsAbsentGroupsAndLayersAlwaysSumToTheTotals() {
    let series = PortfolioAnalytics.stackedSeries(threeRuns, by: .asset)

    XCTAssertEqual(series.layers.first?.id, "BTC")
    let usdc = series.layers.first { $0.id == "USDC" }
    XCTAssertEqual(usdc?.values, [900, 900, 0])
    for index in series.runIDs.indices {
      XCTAssertEqual(
        series.layers.map { $0.values[index] }.reduce(0, +), series.totals[index],
        accuracy: accuracy)
    }
    let runTotals = PortfolioAnalytics.runTotals(threeRuns).map(\.totalValueUsd)
    XCTAssertEqual(series.totals.count, runTotals.count)
    for (stacked, expected) in zip(series.totals, runTotals) {
      XCTAssertEqual(stacked, expected, accuracy: accuracy)
    }
  }

  func testStackedSeriesFoldsTheSmallestLayersIntoOtherWhenAskedToLimitLayers() throws {
    let series = PortfolioAnalytics.stackedSeries(threeRuns, by: .asset, maximumLayers: 3)

    XCTAssertEqual(series.layers.map(\.id), ["BTC", "ETH", StackedSeries.otherLayerID])
    let other = try XCTUnwrap(series.layers.last)
    XCTAssertEqual(other.label, "Other")
    // SOL + ATOM + USDC in the first run.
    XCTAssertEqual(other.values[0], 3_000 + 1_125 + 900, accuracy: accuracy)
    XCTAssertEqual(series.totals[0], 51_525, accuracy: accuracy)
    XCTAssertEqual(
      PortfolioAnalytics.stackedSeries(threeRuns, by: .asset, maximumLayers: 5).layers.count, 5)
    XCTAssertEqual(
      PortfolioAnalytics.stackedSeries(threeRuns, by: .asset, maximumLayers: 50).layers.count, 5)
  }

  func testEmptyHistoryProducesEmptySeries() {
    XCTAssertTrue(PortfolioAnalytics.runTotals([]).isEmpty)
    XCTAssertTrue(PortfolioAnalytics.coinSeries([], coin: "BTC").isEmpty)
    let stacked = PortfolioAnalytics.stackedSeries([], by: .state)
    XCTAssertTrue(stacked.layers.isEmpty)
    XCTAssertTrue(stacked.totals.isEmpty)
    XCTAssertTrue(PortfolioAnalytics.dailySeries([], timeZone: .gmt).isEmpty)
  }

  // MARK: Daily series

  private func dailyRuns() -> [ScanRunRecord] {
    func run(_ time: String, _ id: Int, _ amount: Double) -> ScanRunRecord {
      Fixture.run(
        time, [Fixture.kraken("BTC", amount: amount, price: 100)],
        id: "00000000-0000-4000-8000-00000000000\(id)")
    }
    return [
      run("2026-11-01T23:30:00Z", 1, 1),  // $100
      run("2026-11-02T01:00:00Z", 2, 2),  // $200
      run("2026-11-02T22:00:00Z", 3, 3),  // $300
      run("2026-11-05T12:00:00Z", 4, 6),  // $600
    ]
  }

  func testDailySeriesKeepsTheLastScanOfEachUTCDayAndSkipsGapsWhenComparing() throws {
    var runs = dailyRuns()
    var generator = SeededGenerator(seed: 7)
    runs.shuffle(using: &generator)

    let days = PortfolioAnalytics.dailySeries(runs, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))

    XCTAssertEqual(days.map(\.id), ["2026-11-01", "2026-11-02", "2026-11-05"])
    XCTAssertEqual(days.map(\.totalValueUsd), [100, 300, 600])
    XCTAssertEqual(
      days.map { $0.runID.uuidString.lowercased() },
      [
        "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000004",
      ])
    XCTAssertEqual(days.map(\.changeUsd), [nil, 200, 300])
    XCTAssertEqual(days.map(\.changeFraction), [nil, 2, 1])
    // November 5 compares with November 2, the previous day that has data.
    XCTAssertEqual(days.map(\.previousDay?.id), [nil, "2026-11-01", "2026-11-02"])
    XCTAssertEqual(days[1].dayStart, Fixture.date("2026-11-02T00:00:00Z"))
  }

  func testDailySeriesDrawsDayBoundariesInTheRequestedTimeZone() throws {
    let auckland = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))  // UTC+13 in November
    let days = PortfolioAnalytics.dailySeries(dailyRuns(), timeZone: auckland)

    // 23:30Z and 01:00Z are both November 2 in Auckland; 22:00Z is November 3.
    XCTAssertEqual(days.map(\.id), ["2026-11-02", "2026-11-03", "2026-11-06"])
    XCTAssertEqual(days.map(\.totalValueUsd), [200, 300, 600])
    XCTAssertEqual(days.map(\.changeUsd), [nil, 100, 300])
    XCTAssertEqual(days[0].dayStart, Fixture.date("2026-11-01T11:00:00Z"))

    // Daylight saving ended on November 1, 2026, so Los Angeles is UTC-8 by then.
    let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let western = PortfolioAnalytics.dailySeries(dailyRuns(), timeZone: losAngeles)
    // 23:30Z Nov 1 is 15:30 Nov 1 there; 01:00Z and 22:00Z Nov 2 are Nov 1 17:00 and Nov 2 14:00.
    XCTAssertEqual(western.map(\.id), ["2026-11-01", "2026-11-02", "2026-11-05"])
    XCTAssertEqual(western.map(\.totalValueUsd), [200, 300, 600])
  }

  func testDailyChangeFractionIsNilWhenThePreviousDayWasWorthNothingAndFlagsUnpricedScans() {
    let empty = Fixture.run(
      "2026-11-01T10:00:00Z", [Fixture.kraken("PEPE", amount: 1, price: nil)],
      id: "00000000-0000-4000-8000-000000000001")
    let funded = Fixture.run(
      "2026-11-02T10:00:00Z", [Fixture.kraken("BTC", amount: 1, price: 100)],
      id: "00000000-0000-4000-8000-000000000002")

    let days = PortfolioAnalytics.dailySeries([empty, funded], timeZone: .gmt)

    XCTAssertEqual(days.map(\.totalValueUsd), [0, 100])
    XCTAssertEqual(days.map(\.changeUsd), [nil, 100])
    XCTAssertEqual(days.map(\.changeFraction), [nil, nil])
    XCTAssertEqual(days.map(\.hasUnpricedHoldings), [true, false])
  }
}
