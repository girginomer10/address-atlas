import AddressAtlasCore
import CoreGraphics
import Foundation
import XCTest

@testable import AddressAtlasMac

/// Builds small ATOM-only histories for the coin widget tests, so each case
/// states exactly what changed between scans.
enum CoinWidgetTestRuns {
  static let cosmosAddress = ChartFixture.cosmosAddress
  static let secondCosmosAddress = "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu"

  struct Amounts {
    var liquid = 0.0
    var staked = 0.0
    var unbonding = 0.0
    var rewards = 0.0
    var price = 5.0
    /// Added to the scan as another wallet; changes `inputCount`.
    var extraWallet = false
    var unlocksAt: Date?
  }

  static func atom(
    _ amount: Double, source: AssetSource, price: Double, address: String = cosmosAddress,
    label: String = "Keplr", unlocksAt: Date? = nil
  ) -> TrackedAsset {
    TrackedAsset(
      id: "\(address)-cosmoshub-ATOM-\(source.rawValue)", address: address, chainId: "cosmoshub",
      chainName: "Cosmos Hub", family: .cosmos, symbol: "ATOM", name: "Cosmos Hub ATOM",
      amount: amount, priceUsd: price, valueUsd: price * amount, pricingStatus: .priced,
      source: source, walletLabel: label, unlocksAt: unlocksAt)
  }

  static func run(day: Int, _ amounts: Amounts) -> ScanRunRecord {
    var holdings: [TrackedAsset] = []
    func add(_ amount: Double, _ source: AssetSource, unlocksAt: Date? = nil) {
      guard amount > 0 else { return }
      holdings.append(
        atom(amount, source: source, price: amounts.price, unlocksAt: unlocksAt))
    }
    add(amounts.liquid, .native)
    add(amounts.staked, .staked)
    add(amounts.unbonding, .unbonding, unlocksAt: amounts.unlocksAt)
    add(amounts.rewards, .rewards)
    if amounts.extraWallet {
      holdings.append(
        atom(
          10, source: .native, price: amounts.price, address: secondCosmosAddress,
          label: "Second"))
    }
    let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", day))!
    return ScanRunRecord(
      id: id, generatedAt: ChartFixture.scanDate(day: day, hour: 3),
      totalUsd: holdings.map(\.valueUsd).reduce(0, +),
      inputCount: amounts.extraWallet ? 2 : 1, holdings: holdings)
  }

  static func runs(_ amounts: [Amounts], startingDay: Int = 0) -> [ScanRunRecord] {
    amounts.enumerated().map { run(day: startingDay + $0.offset, $0.element) }
  }
}

// MARK: - Segment layout

final class CoinWidgetSegmentLayoutTests: XCTestCase {
  func testWidthsAddUpToTheSpaceMinusGaps() {
    let widths = CoinWidgetSegmentLayout.widths(
      weights: [90, 8, 2], total: 300, gap: 3, minimum: 4)
    XCTAssertEqual(widths.reduce(0, +) + 6, 300, accuracy: 0.001)
    XCTAssertGreaterThan(widths[0], widths[1])
  }

  func testSliversGetTheMinimumWidth() {
    let widths = CoinWidgetSegmentLayout.widths(
      weights: [1000, 1, 1], total: 200, gap: 2, minimum: 4)
    XCTAssertEqual(widths[1], 4, accuracy: 0.001)
    XCTAssertEqual(widths[2], 4, accuracy: 0.001)
    XCTAssertEqual(widths.reduce(0, +) + 4, 200, accuracy: 0.001)
  }

  func testZeroAndInvalidWeightsAreSkipped() {
    let widths = CoinWidgetSegmentLayout.widths(
      weights: [0, 5, .nan, -2, 5], total: 103, gap: 3, minimum: 4)
    XCTAssertEqual(widths[0], 0)
    XCTAssertEqual(widths[2], 0)
    XCTAssertEqual(widths[3], 0)
    XCTAssertEqual(widths[1], 50, accuracy: 0.001)
    XCTAssertEqual(widths[4], 50, accuracy: 0.001)
    let origins = CoinWidgetSegmentLayout.origins(widths: widths, gap: 3)
    XCTAssertEqual(origins[4], 53, accuracy: 0.001)
  }

  func testNoSegmentsOrNoSpaceGivesZeroWidths() {
    XCTAssertEqual(CoinWidgetSegmentLayout.widths(weights: [], total: 100, gap: 2, minimum: 4), [])
    XCTAssertEqual(
      CoinWidgetSegmentLayout.widths(weights: [1, 2], total: 0, gap: 2, minimum: 4), [0, 0])
  }

  func testMinimumsThatOverflowAreScaledDown() {
    let widths = CoinWidgetSegmentLayout.widths(
      weights: [1, 1, 1, 1], total: 20, gap: 2, minimum: 6)
    XCTAssertEqual(widths.reduce(0, +) + 6, 20, accuracy: 0.001)
  }
}

// MARK: - State strip

final class CoinStateStripModelTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private func summary(_ symbol: String = "ATOM") -> CoinSummary {
    PortfolioAnalytics.coinSummary(ChartFixture.latestHoldings, coin: symbol)!
  }

  func testRowsFollowStateOrderWithAmountsAndValues() {
    let model = CoinStateStripModel(summary: summary())
    XCTAssertEqual(model.rows.map(\.state), [.liquid, .staked, .unbonding, .rewards])
    XCTAssertEqual(model.rowAmountText(model.rows[1]), "280 ATOM")
    XCTAssertEqual(model.rows[2].amountText, "24.79")
    XCTAssertEqual(model.rows.map(\.valueShare).reduce(0, +), 1, accuracy: 1e-9)
    XCTAssertEqual(model.rows.map(\.amountShare).reduce(0, +), 1, accuracy: 1e-9)
  }

  func testHeadlineAndDetailLine() {
    let model = CoinStateStripModel(summary: summary())
    XCTAssertTrue(model.isPriced)
    XCTAssertTrue(model.headline.hasPrefix("$2,"), model.headline)
    XCTAssertTrue(model.detailLine.hasPrefix("310.2 ATOM \u{00B7} $6."), model.detailLine)
    XCTAssertTrue(model.rowValueText(model.rows[1]).hasPrefix("$1,9"))
  }

  func testStripWeightsUseValueWhenPriced() {
    let model = CoinStateStripModel(summary: summary())
    XCTAssertEqual(model.stripWeights, model.rows.map(\.valueUsd))
  }

  func testUnpricedCoinFallsBackToAmountsAndSaysSo() {
    let holdings = [
      TrackedAsset(
        id: "x", address: ChartFixture.evmAddress, chainId: "ethereum", chainName: "Ethereum",
        family: .evm, symbol: "MEME", name: "Meme", amount: 1000, priceUsd: 0, valueUsd: 0,
        pricingStatus: .unpriced, source: .erc20, walletLabel: "Main"),
      TrackedAsset(
        id: "y", address: ChartFixture.evmAddress, chainId: "ethereum", chainName: "Ethereum",
        family: .evm, symbol: "MEME", name: "Meme", amount: 500, priceUsd: 0, valueUsd: 0,
        pricingStatus: .unpriced, source: .staked, walletLabel: "Main"),
    ]
    let model = CoinStateStripModel(summary: PortfolioAnalytics.coinSummary(holdings, coin: "MEME")!)
    XCTAssertFalse(model.isPriced)
    XCTAssertEqual(model.headline, "1,500 MEME")
    XCTAssertEqual(model.detailLine, "No price yet")
    XCTAssertEqual(model.stripWeights, [1000, 500])
    XCTAssertEqual(model.rowValueText(model.rows[0]), "No price")
  }

  func testSpokenSummaryNamesEveryState() {
    let spoken = CoinStateStripModel(summary: summary()).spokenSummary
    for name in ["Liquid", "Staked", "Unbonding", "Rewards"] {
      XCTAssertTrue(spoken.contains(name), spoken)
    }
  }
}

// MARK: - Unlock timeline

final class CoinUnlockTimelineModelTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private let utc = TimeZone(identifier: "UTC") ?? .current
  private let now = ChartFixture.scanDate(day: ChartFixture.dayCount - 1, hour: 1)

  private func model(
    runs: [ScanRunRecord] = ChartFixture.runs(), holdings: [TrackedAsset]? = nil,
    coin: String = "ATOM", now: Date? = nil, timeZone: TimeZone? = nil
  ) -> CoinUnlockTimelineModel {
    let source = holdings ?? ChartFixture.latestHoldings
    return CoinUnlockTimelineModel(
      summary: PortfolioAnalytics.coinSummary(source, coin: coin)!, runs: runs,
      now: now ?? self.now, timeZone: timeZone ?? utc)
  }

  func testDatedUnlockReadsAsAmountAndDate() throws {
    let model = model()
    XCTAssertEqual(model.dated.count, 1)
    let unlock = try XCTUnwrap(model.dated.first)
    XCTAssertEqual(model.sentence(for: unlock), "24.79 ATOM free on Nov 16")
    XCTAssertFalse(unlock.hasPassed)
    XCTAssertEqual(unlock.daysAway, 12)
    XCTAssertEqual(model.relativeText(for: unlock), "in 12 days")
    XCTAssertNil(model.undated)
    XCTAssertFalse(model.isEmpty)
  }

  func testRelativeWordsForTodayAndTomorrow() throws {
    let tomorrowMorning = ChartFixture.unlockDate.addingTimeInterval(-86_400 + 3_600)
    let tomorrow = try XCTUnwrap(model(now: tomorrowMorning).dated.first)
    XCTAssertEqual(tomorrow.daysAway, 1)
    XCTAssertEqual(model(now: tomorrowMorning).relativeText(for: tomorrow), "tomorrow")
    // Unlocks at 18:00 on the 16th, looked at at 08:00 the same day.
    let evening = ChartFixture.unlockDate.addingTimeInterval(18 * 3_600)
    let holdings = [CoinWidgetTestRuns.atom(3, source: .unbonding, price: 5, unlocksAt: evening)]
    let sameDay = model(
      runs: [], holdings: holdings, now: ChartFixture.unlockDate.addingTimeInterval(8 * 3_600))
    let today = try XCTUnwrap(sameDay.dated.first)
    XCTAssertEqual(today.daysAway, 0)
    XCTAssertFalse(today.hasPassed)
    XCTAssertEqual(sameDay.relativeText(for: today), "today")
  }

  func testPastUnlockStillUnbondingSaysToScanAgain() throws {
    let after = ChartFixture.unlockDate.addingTimeInterval(2 * 86_400)
    let model = model(now: after)
    let unlock = try XCTUnwrap(model.dated.first)
    XCTAssertTrue(unlock.hasPassed)
    XCTAssertNil(model.relativeText(for: unlock))
    XCTAssertTrue(
      model.sentence(for: unlock).contains("Unlocked on Nov 16. Scan again to see it as liquid."),
      model.sentence(for: unlock))
  }

  func testSeenSinceIsTheFirstScanOfTheLatestStretch() {
    let model = model()
    XCTAssertEqual(model.seenSince, ChartFixture.run(day: ChartFixture.unstakeDay).generatedAt)
    XCTAssertEqual(model.seenSinceText, "Seen unbonding on Oct 21")
  }

  func testSeenSinceIgnoresAnEarlierClosedStretch() {
    let unbonding = CoinWidgetTestRuns.Amounts(staked: 100, unbonding: 10, unlocksAt: ChartFixture.unlockDate)
    let none = CoinWidgetTestRuns.Amounts(staked: 110)
    let runs = CoinWidgetTestRuns.runs([unbonding, unbonding, none, none, unbonding, unbonding])
    let holdings = runs[5].holdings
    XCTAssertEqual(
      model(runs: runs, holdings: holdings).seenSince, runs[4].generatedAt)
  }

  func testSeenSinceIsNilWithoutRunsOrWhenTheLatestRunHasNoUnbonding() {
    XCTAssertNil(model(runs: []).seenSince)
    let none = CoinWidgetTestRuns.Amounts(staked: 110)
    let unbonding = CoinWidgetTestRuns.Amounts(staked: 100, unbonding: 10, unlocksAt: ChartFixture.unlockDate)
    let runs = CoinWidgetTestRuns.runs([unbonding, none])
    XCTAssertNil(model(runs: runs, holdings: runs[0].holdings).seenSince)
  }

  func testSolanaUnbondingWithoutADateReadsAsEndOfEpoch() throws {
    let holdings = [
      TrackedAsset(
        id: "sol-unb", address: ChartFixture.solanaAddress, chainId: "solana", chainName: "Solana",
        family: .solana, symbol: "SOL", name: "Solana SOL", amount: 12, priceUsd: 140,
        valueUsd: 1_680, pricingStatus: .priced, source: .unbonding, walletLabel: "Phantom")
    ]
    let model = model(runs: [], holdings: holdings, coin: "SOL")
    XCTAssertTrue(model.dated.isEmpty)
    let undated = try XCTUnwrap(model.undated)
    XCTAssertEqual(undated.reason, .endOfEpoch)
    XCTAssertEqual(model.sentence(for: undated), "12 SOL unlocks at the end of the current epoch")
    XCTAssertFalse(model.isEmpty)
  }

  func testUndatedUnbondingElsewhereSaysTheTimeIsNotReported() throws {
    let holdings = [CoinWidgetTestRuns.atom(5, source: .unbonding, price: 5)]
    let model = model(runs: [], holdings: holdings)
    let undated = try XCTUnwrap(model.undated)
    XCTAssertEqual(undated.reason, .notReported)
    XCTAssertEqual(
      model.sentence(for: undated), "5 ATOM: Unlock time not reported by the network")
  }

  func testNothingUnbondingIsEmpty() {
    let holdings = [CoinWidgetTestRuns.atom(5, source: .native, price: 5)]
    XCTAssertTrue(model(runs: [], holdings: holdings).isEmpty)
    XCTAssertTrue(model(coin: "ETH").isEmpty)
  }

  func testSeveralUnlockDatesAreSortedSoonestFirst() {
    let early = ChartFixture.unlockDate
    let late = early.addingTimeInterval(5 * 86_400)
    let holdings = [
      CoinWidgetTestRuns.atom(3, source: .unbonding, price: 5, unlocksAt: late),
      TrackedAsset(
        id: "second", address: ChartFixture.cosmosAddress, chainId: "cosmoshub",
        chainName: "Cosmos Hub", family: .cosmos, symbol: "ATOM", name: "ATOM", amount: 4,
        priceUsd: 5, valueUsd: 20, pricingStatus: .priced, source: .unbonding,
        walletLabel: "Keplr", unlocksAt: early),
    ]
    let model = model(runs: [], holdings: holdings)
    XCTAssertEqual(model.dated.map(\.date), [early, late])
    XCTAssertEqual(model.totalAmount, 7, accuracy: 1e-9)
  }

  func testDayCountsUseTheChartsTimeZoneAcrossDaylightSaving() throws {
    // 25 Oct 2026 is 25 hours long in Paris (clocks go back). 24 hours after
    // noon on the 24th is still the 25th, and the 26th is two calendar days on.
    let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = paris
    let noon24 = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 12)))
    let morning26 = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8)))
    let holdings = [CoinWidgetTestRuns.atom(3, source: .unbonding, price: 5, unlocksAt: morning26)]
    let model = model(runs: [], holdings: holdings, now: noon24, timeZone: paris)
    XCTAssertEqual(model.dated.first?.daysAway, 2)
  }

  // MARK: Scale

  func testScalePutsTodayBetweenTheEnds() {
    let model = model()
    let scale = CoinUnlockTimelineScale(model: model)
    XCTAssertEqual(scale.position(of: scale.start), 0, accuracy: 1e-9)
    XCTAssertEqual(scale.position(of: scale.end), 1, accuracy: 1e-9)
    let today = scale.position(of: model.now)
    XCTAssertGreaterThan(today, 0)
    XCTAssertLessThan(today, 1)
  }

  func testScaleWithoutAStartBeginsToday() {
    let scale = CoinUnlockTimelineScale(model: model(runs: []))
    XCTAssertEqual(scale.start, now)
    XCTAssertEqual(scale.position(of: now), 0, accuracy: 1e-9)
  }

  func testScaleStaysNonEmptyWhenEverythingIsToday() {
    let holdings = [CoinWidgetTestRuns.atom(3, source: .unbonding, price: 5, unlocksAt: now)]
    let scale = CoinUnlockTimelineScale(model: model(runs: [], holdings: holdings))
    XCTAssertGreaterThan(scale.end, scale.start)
  }
}

// MARK: - Amount history

final class CoinAmountHistoryModelTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private func model(
    _ runs: [ScanRunRecord], coin: String = "ATOM", maximum: Int = 3
  ) -> CoinAmountHistoryModel? {
    CoinAmountHistoryModel.make(runs: runs, coinKey: coin, context: nil, maximumAnnotations: maximum)
  }

  func testFixtureAtomFindsTheUnstakeAndTheSourceChange() throws {
    let runs = ChartFixture.runs()
    let model = try XCTUnwrap(model(runs))
    XCTAssertEqual(model.runCount, runs.count)
    XCTAssertEqual(model.layers.map(\.state), [.liquid, .staked, .unbonding, .rewards])
    let unstakeIndex = try XCTUnwrap(
      model.runIDs.firstIndex(of: ChartFixture.run(day: ChartFixture.unstakeDay).id))
    let annotation = try XCTUnwrap(model.annotations.first)
    XCTAssertEqual(model.annotations.count, 1)
    XCTAssertEqual(annotation.kind, .transfer)
    XCTAssertEqual(annotation.runIndex, unstakeIndex)
    XCTAssertEqual(annotation.text, "Unstaked 24.79")
    // One break, between the last scan of day 19 and the first of day 20.
    XCTAssertEqual(model.sourceBreaks.filter { $0 }.count, 1)
    let breakIndex = try XCTUnwrap(model.sourceBreaks.firstIndex(of: true))
    XCTAssertEqual(
      model.runIDs[breakIndex + 1], ChartFixture.run(day: ChartFixture.sourceChangeDay).id)
    XCTAssertEqual(model.segments.count, 2)
    XCTAssertEqual(model.segments[0].upperBound, breakIndex + 1)
    XCTAssertEqual(model.segments[1].lowerBound, breakIndex + 1)
    XCTAssertEqual(model.segments[1].upperBound, model.runCount)
  }

  func testLayersStackToTheTotalsInCoins() throws {
    let model = try XCTUnwrap(model(ChartFixture.runs()))
    for index in 0..<model.runCount {
      let sum = model.layers.map { $0.values[index] }.reduce(0, +)
      XCTAssertEqual(sum, model.totals[index], accuracy: 1e-9)
    }
    // Coins, not dollars: the latest total is the held amount.
    XCTAssertEqual(model.totals.last ?? 0, 4.2 + 280 + 24.79 + 1.21, accuracy: 1e-6)
  }

  func testRunsAreOrderedEvenWhenGivenShuffled() throws {
    let runs = ChartFixture.runs()
    let shuffled = Array(runs.reversed())
    let model = try XCTUnwrap(model(shuffled))
    XCTAssertEqual(model.runIDs, runs.map(\.id))
  }

  func testRewardsCreepIsNotAnnotated() throws {
    var amounts: [CoinWidgetTestRuns.Amounts] = []
    for index in 0..<6 {
      amounts.append(.init(liquid: 5, staked: 300, rewards: 0.2 * Double(index)))
    }
    let model = try XCTUnwrap(model(CoinWidgetTestRuns.runs(amounts)))
    XCTAssertTrue(model.annotations.isEmpty)
  }

  func testTransfersAreNamedByWhatMovedWhere() throws {
    func annotation(_ before: CoinWidgetTestRuns.Amounts, _ after: CoinWidgetTestRuns.Amounts)
      throws -> String
    {
      let model = try XCTUnwrap(model(CoinWidgetTestRuns.runs([before, after])))
      return try XCTUnwrap(model.annotations.first).text
    }
    XCTAssertEqual(
      try annotation(.init(staked: 100), .init(staked: 80, unbonding: 20)), "Unstaked 20")
    XCTAssertEqual(
      try annotation(.init(staked: 80, unbonding: 20), .init(liquid: 20, staked: 80)), "Unlocked 20")
    XCTAssertEqual(
      try annotation(.init(liquid: 50, staked: 50), .init(liquid: 30, staked: 70)), "Staked 20")
    XCTAssertEqual(
      try annotation(.init(liquid: 50, staked: 50, rewards: 10), .init(liquid: 60, staked: 50)),
      "Claimed 10")
    XCTAssertEqual(
      try annotation(.init(staked: 50, unbonding: 50), .init(staked: 70, unbonding: 30)),
      "Moved 20")
  }

  func testReceivedAndSentUseTheNetChange() throws {
    let received = try XCTUnwrap(
      model(CoinWidgetTestRuns.runs([.init(staked: 100), .init(liquid: 2.5, staked: 100)])))
    XCTAssertEqual(received.annotations.map(\.text), ["Received 2.5"])
    XCTAssertEqual(received.annotations.first?.kind, .received)
    let sent = try XCTUnwrap(
      model(CoinWidgetTestRuns.runs([.init(liquid: 3, staked: 100), .init(staked: 100)])))
    XCTAssertEqual(sent.annotations.map(\.text), ["Sent 3"])
    XCTAssertEqual(sent.annotations.first?.kind, .sent)
  }

  func testChangesUnderHalfAPercentAreNotLabelled() throws {
    let quiet = try XCTUnwrap(
      model(CoinWidgetTestRuns.runs([.init(staked: 1000), .init(liquid: 4, staked: 1000)])))
    XCTAssertTrue(quiet.annotations.isEmpty)
    let labelled = try XCTUnwrap(
      model(CoinWidgetTestRuns.runs([.init(staked: 1000), .init(liquid: 5.1, staked: 1000)])))
    XCTAssertEqual(labelled.annotations.count, 1)
  }

  func testAChangeAcrossASourceChangeIsNotClaimedAsReceived() throws {
    let runs = CoinWidgetTestRuns.runs([
      .init(staked: 100), .init(staked: 100), .init(staked: 100, extraWallet: true),
      .init(staked: 100, extraWallet: true),
    ])
    let model = try XCTUnwrap(model(runs))
    XCTAssertEqual(model.sourceBreaks, [false, true, false])
    XCTAssertTrue(model.annotations.isEmpty)
    XCTAssertTrue(model.hasSourceChange)
  }

  func testAnnotationCapKeepsTheLargestAndSortsByTime() throws {
    let steps: [CoinWidgetTestRuns.Amounts] = [
      .init(liquid: 100), .init(liquid: 110), .init(liquid: 130), .init(liquid: 105),
      .init(liquid: 160), .init(liquid: 160),
    ]
    let runs = CoinWidgetTestRuns.runs(steps)
    let all = try XCTUnwrap(model(runs, maximum: 10))
    XCTAssertEqual(all.annotations.map(\.text), ["Received 10", "Received 20", "Sent 25", "Received 55"])
    let capped = try XCTUnwrap(model(runs, maximum: 2))
    XCTAssertEqual(capped.annotations.map(\.text), ["Sent 25", "Received 55"])
    let one = try XCTUnwrap(model(runs, maximum: 1))
    XCTAssertEqual(one.annotations.map(\.text), ["Received 55"])
    XCTAssertTrue(try XCTUnwrap(model(runs, maximum: 0)).annotations.isEmpty)
  }

  func testNeedsTwoRunsAndTheCoin() {
    XCTAssertNil(model([ChartFixture.run(day: 0)]))
    XCTAssertNil(model([]))
    XCTAssertNil(model(ChartFixture.runs(), coin: "NOPE"))
  }

  func testTooltipListsAmountsPerStateAndTheSourceChange() throws {
    let model = try XCTUnwrap(model(ChartFixture.runs()))
    let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let last = model.runCount - 1
    let lines = model.tooltipLines(at: last, timeZone: utc)
    XCTAssertTrue(lines.contains("Staked 280"), "\(lines)")
    XCTAssertTrue(lines.contains("Unbonding 24.79"), "\(lines)")
    let breakIndex = try XCTUnwrap(model.sourceBreaks.firstIndex(of: true))
    XCTAssertTrue(
      model.tooltipLines(at: breakIndex + 1, timeZone: utc).contains("Sources changed since the scan before"))
    XCTAssertEqual(model.tooltipLines(at: 999, timeZone: utc), [])
  }
}

// MARK: - Change

final class CoinChangeModelTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private let utc = TimeZone(identifier: "UTC") ?? .current

  private func make(_ runs: [ScanRunRecord], coin: String = "ETH") -> CoinChangeModel {
    CoinChangeModel.make(runs: runs, coinKey: coin, context: nil, timeZone: utc)
  }

  func testFixtureEthSplitsPriceFromAmount() throws {
    let model = make(ChartFixture.runs())
    let comparison = try XCTUnwrap(model.comparison)
    XCTAssertEqual(comparison.status, .changed)
    XCTAssertEqual(
      comparison.priceEffectUsd + comparison.amountEffectUsd + comparison.valuationGapUsd,
      comparison.deltaUsd, accuracy: 1e-6)
    XCTAssertEqual(model.headline?.hasPrefix("ETH changed +$"), true, model.headline ?? "")
    XCTAssertEqual(model.headline?.hasSuffix("since Nov 3"), true, model.headline ?? "")
    XCTAssertTrue(try XCTUnwrap(model.priceSentence).hasPrefix("Price went from $3,"))
    XCTAssertEqual(model.amountSentence, "You hold 0.0094 ETH more, on Base.")
    XCTAssertEqual(model.effects.map(\.kind), [.price, .amount])
  }

  func testPriceOnlyMoveSaysNoCoinsMoved() throws {
    let runs = CoinWidgetTestRuns.runs([
      .init(staked: 100, price: 5), .init(staked: 100, price: 6),
    ])
    let model = make(runs, coin: "ATOM")
    XCTAssertEqual(model.headline, "ATOM changed +$100 since Sep 24")
    XCTAssertEqual(model.priceSentence, "Price went from $5.00 to $6.00.")
    XCTAssertEqual(model.amountSentence, "You did not receive or send any ATOM.")
    XCTAssertEqual(try XCTUnwrap(model.comparison).amountEffectUsd, 0, accuracy: 1e-9)
  }

  func testLessWithAPlaceIsMostlyWhenSplitAcrossLocations() throws {
    let before = [
      CoinWidgetTestRuns.atom(60, source: .native, price: 5),
      CoinWidgetTestRuns.atom(
        40, source: .native, price: 5, address: CoinWidgetTestRuns.secondCosmosAddress, label: "Second"),
    ]
    let after = [
      CoinWidgetTestRuns.atom(10, source: .native, price: 5),
      CoinWidgetTestRuns.atom(
        20, source: .native, price: 5, address: CoinWidgetTestRuns.secondCosmosAddress, label: "Second"),
    ]
    func run(_ day: Int, _ holdings: [TrackedAsset]) -> ScanRunRecord {
      ScanRunRecord(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", day))!,
        generatedAt: ChartFixture.scanDate(day: day), totalUsd: holdings.map(\.valueUsd).reduce(0, +),
        inputCount: 2, holdings: holdings)
    }
    let model = make([run(0, before), run(1, after)], coin: "ATOM")
    // Two wallets on one network read as one place: 70 less, all on Cosmos Hub.
    XCTAssertEqual(model.amountSentence, "You hold 70 ATOM less, on Cosmos Hub.")
    XCTAssertEqual(try XCTUnwrap(model.comparison).mainLocation?.share ?? 0, 1, accuracy: 1e-9)
  }

  func testLessIsMostlyOnTheBiggestNetworkWhenSeveralLost() throws {
    func eth(_ amount: Double, wallet: Bool) -> TrackedAsset {
      if wallet {
        return TrackedAsset(
          id: "\(ChartFixture.evmAddress)-ethereum-ETH", address: ChartFixture.evmAddress,
          chainId: "ethereum", chainName: "Ethereum", family: .evm, symbol: "ETH", name: "ETH",
          amount: amount, priceUsd: 3_000, valueUsd: amount * 3_000, pricingStatus: .priced,
          source: .native, walletLabel: "Main")
      }
      return TrackedAsset(
        id: "\(ChartFixture.krakenID.uuidString)-kraken-ETH", address: "Kraken", chainId: "kraken",
        chainName: "Kraken", family: .exchange, symbol: "ETH", name: "ETH", amount: amount,
        priceUsd: 3_000, valueUsd: amount * 3_000, pricingStatus: .priced, source: .exchange,
        walletLabel: "Kraken", exchangeId: ChartFixture.krakenID, exchangeProvider: .kraken)
    }
    func run(_ day: Int, _ holdings: [TrackedAsset]) -> ScanRunRecord {
      ScanRunRecord(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", day))!,
        generatedAt: ChartFixture.scanDate(day: day), totalUsd: holdings.map(\.valueUsd).reduce(0, +),
        inputCount: 2, holdings: holdings)
    }
    let model = make([
      run(0, [eth(1.0, wallet: true), eth(0.6, wallet: false)]),
      run(1, [eth(0.4, wallet: true), eth(0.4, wallet: false)]),
    ])
    XCTAssertEqual(model.amountSentence, "You hold 0.8 ETH less, mostly on Ethereum.")
  }

  func testAddedAndRemovedCoins() throws {
    // The same wallet holds LINK in both scans; ETH shows up in the second.
    func holding(_ symbol: String, _ amount: Double, _ price: Double) -> TrackedAsset {
      TrackedAsset(
        id: "\(ChartFixture.evmAddress)-ethereum-\(symbol)", address: ChartFixture.evmAddress,
        chainId: "ethereum", chainName: "Ethereum", family: .evm, symbol: symbol,
        name: symbol, amount: amount, priceUsd: price, valueUsd: amount * price,
        pricingStatus: .priced, source: .native, walletLabel: "Main")
    }
    func run(_ day: Int, _ holdings: [TrackedAsset]) -> ScanRunRecord {
      ScanRunRecord(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", day))!,
        generatedAt: ChartFixture.scanDate(day: day), totalUsd: holdings.map(\.valueUsd).reduce(0, +),
        inputCount: 1, holdings: holdings)
    }
    let link = holding("LINK", 10, 15)
    let eth = holding("ETH", 2, 3_000)
    let added = make([run(0, [link]), run(1, [link, eth])])
    XCTAssertEqual(added.comparison?.status, .added)
    XCTAssertEqual(added.amountSentence, "You now hold ETH. It was not in the earlier scan.")
    XCTAssertNil(added.priceSentence)
    XCTAssertEqual(try XCTUnwrap(added.comparison).amountEffectUsd, 6_000, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(added.comparison).priceEffectUsd, 0, accuracy: 1e-9)
    XCTAssertEqual(added.headline, "ETH is new since Sep 24: +$6,000")

    let removed = make([run(0, [link, eth]), run(1, [link])])
    XCTAssertEqual(removed.comparison?.status, .removed)
    XCTAssertEqual(removed.amountSentence, "You no longer hold ETH.")
    XCTAssertEqual(try XCTUnwrap(removed.comparison).amountEffectUsd, -6_000, accuracy: 1e-9)
  }

  func testUnchangedCoin() {
    let amounts = CoinWidgetTestRuns.Amounts(staked: 100)
    let model = make(CoinWidgetTestRuns.runs([amounts, amounts]), coin: "ATOM")
    XCTAssertEqual(model.comparison?.status, .unchanged)
    XCTAssertEqual(model.headline, "ATOM did not change since Sep 24")
    XCTAssertEqual(model.priceSentence, "Price did not change.")
    XCTAssertEqual(model.amountSentence, "You did not receive or send any ATOM.")
  }

  func testNotComparableWhenSourcesDiffer() {
    let runs = CoinWidgetTestRuns.runs([.init(staked: 100), .init(staked: 100, extraWallet: true)])
    let model = make(runs, coin: "ATOM")
    XCTAssertEqual(model.outcome, .notComparable)
    XCTAssertEqual(
      model.message,
      "Your sources changed since your earlier scans, so there is no like-for-like comparison.")
    XCTAssertNil(model.headline)
  }

  func testSkipsBackToTheLatestComparableScan() throws {
    let runs = CoinWidgetTestRuns.runs([
      .init(staked: 100, price: 4), .init(staked: 100, price: 5, extraWallet: true),
      .init(staked: 100, price: 6, extraWallet: true),
    ])
    let model = make(runs, coin: "ATOM")
    let comparison = try XCTUnwrap(model.comparison)
    // The second scan is the comparable one; the first read different sources.
    XCTAssertEqual(comparison.olderPriceUsd ?? 0, 5, accuracy: 1e-9)
  }

  func testNeedsTwoScansAndToHoldTheCoin() {
    XCTAssertEqual(make([ChartFixture.run(day: 0)]).message, "Save another scan to see why this coin's value changes.")
    XCTAssertEqual(make(ChartFixture.runs(), coin: "NOPE").outcome, .noCoin)
    XCTAssertEqual(make(ChartFixture.runs(), coin: "NOPE").message, "No NOPE in your last two scans.")
  }

  func testMissingPriceInOneScanIsAValuationGapNotAPriceMove() throws {
    let unpricedAtom = TrackedAsset(
      id: "\(ChartFixture.cosmosAddress)-cosmoshub-ATOM-native", address: ChartFixture.cosmosAddress,
      chainId: "cosmoshub", chainName: "Cosmos Hub", family: .cosmos, symbol: "ATOM",
      name: "ATOM", amount: 100, priceUsd: 0, valueUsd: 0, pricingStatus: .unpriced,
      source: .native, walletLabel: "Keplr")
    let priced = CoinWidgetTestRuns.run(day: 0, .init(liquid: 100))
    let later = ScanRunRecord(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!,
      generatedAt: ChartFixture.scanDate(day: 1, hour: 3), totalUsd: 0, inputCount: 1,
      holdings: [unpricedAtom])
    let model = make([priced, later], coin: "ATOM")
    let comparison = try XCTUnwrap(model.comparison)
    XCTAssertEqual(comparison.valuationGapUsd, -500, accuracy: 1e-9)
    XCTAssertEqual(comparison.priceEffectUsd, 0, accuracy: 1e-9)
    XCTAssertEqual(model.effects.map(\.kind), [.price, .amount, .valuation])
    XCTAssertTrue(try XCTUnwrap(model.priceSentence).contains("no price"))
  }
}

// MARK: - Custody

final class CoinCustodyModelTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private func model(_ symbol: String) -> CoinCustodyModel {
    CoinCustodyModel(
      summary: PortfolioAnalytics.coinSummary(ChartFixture.latestHoldings, coin: symbol)!)
  }

  func testBitcoinIsEightyEightPercentSelfCustody() throws {
    let model = model("BTC")
    XCTAssertEqual(model.headline, "88%")
    XCTAssertEqual(model.sentence, "0.362 of 0.412 BTC is in your own wallets")
    XCTAssertEqual(model.parts.map(\.side), [.wallet, .exchange])
    XCTAssertEqual(model.parts[0].sources.map(\.label), ["Cold storage"])
    XCTAssertEqual(model.parts[1].sources.map(\.label), ["Kraken"])
    XCTAssertEqual(model.parts.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
    XCTAssertNil(model.manualNote)
  }

  func testStakedAndUnbondingStayInYourWallet() {
    let model = model("ATOM")
    XCTAssertEqual(model.headline, "100%")
    XCTAssertTrue(model.sentence.hasPrefix("All 310.2 ATOM is in your own wallets"), model.sentence)
    XCTAssertEqual(model.parts.map(\.side), [.wallet])
  }

  func testEthSplitsWalletsAcrossNetworksIntoOneSourcePerWallet() throws {
    let model = model("ETH")
    let wallet = try XCTUnwrap(model.part(.wallet))
    // "Main" on Ethereum and Base, and "Savings": two wallets, not three places.
    XCTAssertEqual(Set(wallet.sources.map(\.label)), ["Main", "Savings"])
    let main = try XCTUnwrap(wallet.sources.first { $0.label == "Main" })
    XCTAssertEqual(main.amount, 2.6 + 1.0094, accuracy: 1e-9)
    XCTAssertEqual(model.part(.exchange)?.sources.map(\.label), ["Kraken"])
  }

  func testNothingInWalletsReadsAsNone() throws {
    let model = model("USDC")
    XCTAssertEqual(model.part(.wallet)?.side, .wallet)  // Savings holds 500 USDC
    let exchangeOnly = [
      TrackedAsset(
        id: "k", address: "Kraken", chainId: "kraken", chainName: "Kraken", family: .exchange,
        symbol: "DOGE", name: "DOGE", amount: 100, priceUsd: 0.1, valueUsd: 10,
        pricingStatus: .priced, source: .exchange, walletLabel: "Kraken",
        exchangeId: ChartFixture.krakenID, exchangeProvider: .kraken)
    ]
    let none = CoinCustodyModel(
      summary: PortfolioAnalytics.coinSummary(exchangeOnly, coin: "DOGE")!)
    XCTAssertEqual(none.headline, "0%")
    XCTAssertEqual(none.sentence, "None of your 100 DOGE is in your own wallets")
    XCTAssertEqual(none.parts.map(\.side), [.exchange])
  }

  func testManualHoldingsHaveUnknownCustody() throws {
    let holdings = [
      TrackedAsset(
        id: "w", address: ChartFixture.bitcoinAddress, chainId: "bitcoin", chainName: "Bitcoin",
        family: .bitcoin, symbol: "BTC", name: "BTC", amount: 0.3, priceUsd: 60_000,
        valueUsd: 18_000, pricingStatus: .priced, source: .native, walletLabel: "Cold"),
      TrackedAsset(
        id: "manual-11111111-2222-4333-8444-555555555555", address: "Hardware wallet",
        chainId: "manual-Manual", chainName: "Ledger", family: .exchange, symbol: "BTC",
        name: "BTC", amount: 0.1, priceUsd: 60_000, valueUsd: 6_000, pricingStatus: .priced,
        source: .exchange),
    ]
    let model = CoinCustodyModel(summary: PortfolioAnalytics.coinSummary(holdings, coin: "BTC")!)
    XCTAssertEqual(model.parts.map(\.side), [.wallet, .manual])
    XCTAssertEqual(model.headline, "75%")
    XCTAssertEqual(model.sentence, "0.3 of 0.4 BTC is in your own wallets")
    XCTAssertEqual(
      model.manualNote, "0.1 BTC was entered by hand, so who holds the keys is not known.")
    XCTAssertEqual(model.part(.manual)?.sources.first?.id.hasPrefix("manual:"), true)
  }

  func testAnAmountlessCoinHasNoShare() {
    let zero = [
      TrackedAsset(
        id: "z", address: ChartFixture.bitcoinAddress, chainId: "bitcoin", chainName: "Bitcoin",
        family: .bitcoin, symbol: "BTC", name: "BTC", amount: 0, priceUsd: 0, valueUsd: 0,
        pricingStatus: .unpriced, source: .native, walletLabel: "Cold")
    ]
    let model = CoinCustodyModel(summary: PortfolioAnalytics.coinSummary(zero, coin: "BTC")!)
    XCTAssertNil(model.selfCustodyShare)
    XCTAssertEqual(model.headline, "\u{2014}")
    XCTAssertTrue(model.parts.isEmpty)
  }

  func testWalletTotalsMatchTheLocationsTheyAreBuiltFrom() {
    for symbol in ["BTC", "ETH", "ATOM", "USDC"] {
      let model = model(symbol)
      for part in model.parts {
        XCTAssertEqual(
          part.sources.map(\.amount).reduce(0, +), part.amount, accuracy: 1e-9, "\(symbol) \(part.side)")
      }
    }
  }
}
