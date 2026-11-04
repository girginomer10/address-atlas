import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

/// Over time, What changed, Slope, Concentration, and the shared formatting and
/// axis helpers: the math and the words, without drawing anything.
final class HistoryChartModelTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC") ?? .current

  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  // MARK: Formatting

  func testMoneyAndShareFormatting() {
    XCTAssertEqual(HistoryChartFormat.usd(48_120), "$48,120")
    XCTAssertEqual(HistoryChartFormat.usd(6.8), "$6.80")
    XCTAssertEqual(HistoryChartFormat.usd(0), "$0")
    XCTAssertEqual(HistoryChartFormat.usdCompact(48_000), "$48K")
    XCTAssertEqual(HistoryChartFormat.usdCompact(1_300_000), "$1.3M")
    XCTAssertEqual(HistoryChartFormat.usdCompact(830), "$830")
    XCTAssertEqual(HistoryChartFormat.signedUsd(410), "+$410")
    XCTAssertEqual(HistoryChartFormat.signedUsd(-46), "\u{2212}$46")
    XCTAssertEqual(HistoryChartFormat.signedUsd(0), "$0")
    XCTAssertEqual(HistoryChartFormat.percent(0.571), "57%")
    XCTAssertEqual(HistoryChartFormat.percent(0.003), "<1%")
    XCTAssertEqual(HistoryChartFormat.percent(0), "0%")
    XCTAssertEqual(HistoryChartFormat.signedPercent(0.009), "+0.9%")
    XCTAssertEqual(HistoryChartFormat.signedPercent(-0.014), "\u{2212}1.4%")
    XCTAssertEqual(HistoryChartFormat.amount(24.79), "24.79")
    XCTAssertEqual(HistoryChartFormat.amount(0.0094), "0.0094")
    XCTAssertEqual(HistoryChartFormat.amount(1_204.5), "1,204.5")
    XCTAssertEqual(HistoryChartFormat.count(1, "coin"), "1 coin")
    XCTAssertEqual(HistoryChartFormat.count(3, "coin"), "3 coins")
  }

  func testNonFiniteValuesNeverReachTheScreen() {
    XCTAssertEqual(HistoryChartFormat.usd(.nan), "$0")
    XCTAssertEqual(HistoryChartFormat.usd(.infinity), "$0")
    XCTAssertEqual(HistoryChartFormat.percent(.nan), "0%")
    XCTAssertEqual(HistoryChartFormat.amount(.infinity), "0")
    XCTAssertEqual(HistoryChartMath.finite(Double.nan), 0)
  }

  // MARK: Axis

  func testAxisPicksNiceStepsThatHugTheData() {
    let wide = HistoryChartMath.axis(maximum: 58_500, intervals: 4)
    XCTAssertEqual(wide.top, 60_000, accuracy: 0.001)
    XCTAssertEqual(wide.step, 20_000, accuracy: 0.001)
    let compact = HistoryChartMath.axis(maximum: 60_500, intervals: 2)
    XCTAssertEqual(compact.top, 75_000, accuracy: 0.001)
    XCTAssertEqual(compact.step, 25_000, accuracy: 0.001)
    let small = HistoryChartMath.axis(maximum: 0.7, intervals: 4)
    XCTAssertGreaterThanOrEqual(small.top, 0.7)
    XCTAssertLessThan(small.top, 1.0)
    XCTAssertEqual(HistoryChartMath.axis(maximum: 0, intervals: 4).top, 1)
    for maximum in stride(from: 1.0, through: 1_000_000, by: 37_311.7) {
      let axis = HistoryChartMath.axis(maximum: maximum, intervals: 4)
      XCTAssertGreaterThanOrEqual(axis.top, maximum - 1e-6)
      XCTAssertLessThan(axis.top, maximum * 2 + axis.step, "max \(maximum)")
    }
  }

  // MARK: Over time

  func testOverTimeNeedsTwoScans() {
    XCTAssertNil(
      OverTimeModel.make(
        runs: [ChartFixture.run(day: 0)], grouping: .asset, context: nil, maximumLayers: 5))
    XCTAssertNil(OverTimeModel.make(runs: [], grouping: .asset, context: nil, maximumLayers: 5))
  }

  func testOverTimeMarksTheSourceChangeAndStacksToTheTotals() throws {
    let model = try XCTUnwrap(
      OverTimeModel.make(
        runs: ChartFixture.runs(), grouping: .asset, context: nil, maximumLayers: 5))
    XCTAssertEqual(model.count, ChartFixture.scanSchedule.count)
    XCTAssertEqual(model.breaks.count, model.count - 1)
    XCTAssertEqual(model.breaks.filter { $0 }.count, 1, "one wallet was added")
    let breakIndex = try XCTUnwrap(model.breaks.firstIndex(of: true))
    let before = model.series.dates[breakIndex]
    let after = model.series.dates[breakIndex + 1]
    XCTAssertLessThan(before, ChartFixture.scanDate(day: ChartFixture.sourceChangeDay))
    XCTAssertGreaterThanOrEqual(after, ChartFixture.scanDate(day: ChartFixture.sourceChangeDay))
    XCTAssertEqual(model.segments.count, 2)
    XCTAssertEqual(model.segments[0].upperBound, breakIndex)
    XCTAssertEqual(model.segments[1].lowerBound, breakIndex + 1)
    XCTAssertTrue(model.hasBreaks)

    // Layers are capped, the remainder is one "Other" layer, and the stack adds
    // up to the totals.
    XCTAssertEqual(model.series.layers.count, 5)
    XCTAssertEqual(model.series.layers.last?.id, StackedSeries.otherLayerID)
    XCTAssertEqual(model.namedLayers.count, 4)
    let edges = model.edges
    for index in 0..<model.count {
      XCTAssertEqual(edges.last?[index] ?? 0, model.series.totals[index], accuracy: 0.01)
    }
    XCTAssertGreaterThan(model.maximumTotal, 0)
  }

  func testOverTimeSegmentsHandleEveryBreakPattern() {
    XCTAssertEqual(OverTimeModel.segments(breaks: [false, false]), [0...2])
    XCTAssertEqual(OverTimeModel.segments(breaks: [true]), [0...0, 1...1])
    XCTAssertEqual(OverTimeModel.segments(breaks: [false, true, false]), [0...1, 2...3])
    XCTAssertEqual(OverTimeModel.segments(breaks: [true, true]), [0...0, 1...1, 2...2])
  }

  func testOverTimeKeepsOnlyTheLatestScansOfALongHistory() throws {
    let many = (0..<(OverTimeModel.maximumRuns + 30)).map { index -> ScanRunRecord in
      var run = ChartFixture.run(day: 41)
      run.id = UUID()
      run.generatedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 3_600)
      return run
    }
    let model = try XCTUnwrap(
      OverTimeModel.make(runs: many, grouping: .state, context: nil, maximumLayers: 5))
    XCTAssertEqual(model.count, OverTimeModel.maximumRuns)
    XCTAssertEqual(
      model.series.dates.last, many.map(\.generatedAt).max())
  }

  func testOverTimeFollowsOneCoinWhenTheInputNamesIt() throws {
    let model = try XCTUnwrap(
      OverTimeModel.make(
        runs: ChartFixture.runs(), grouping: .network, context: nil, coin: "ETH",
        maximumLayers: 5))
    let ethByRun = PortfolioAnalytics.coinSeries(ChartFixture.runs(), coin: "ETH").map(\.valueUsd)
    XCTAssertEqual(model.series.totals.count, ethByRun.count)
    for (total, expected) in zip(model.series.totals, ethByRun) {
      XCTAssertEqual(total, expected, accuracy: 0.01)
    }
    XCTAssertTrue(model.series.layers.contains { $0.id == "ethereum" })
    XCTAssertTrue(model.series.layers.contains { $0.id == "kraken" })
  }

  func testOverTimeHasNoBreakBetweenScansOfTheSameSources() throws {
    let runs = [ChartFixture.run(day: 18), ChartFixture.run(day: 19, hour: 0)]
    let model = try XCTUnwrap(
      OverTimeModel.make(runs: runs, grouping: .asset, context: nil, maximumLayers: 5))
    XCTAssertFalse(model.hasBreaks)
    XCTAssertEqual(model.segments, [0...1])
  }

  func testOverTimeWordsForTooltipsAndVoiceOver() throws {
    let model = try XCTUnwrap(
      OverTimeModel.make(
        runs: ChartFixture.runs(), grouping: .asset, context: nil, maximumLayers: 5))
    let breakIndex = try XCTUnwrap(model.breaks.firstIndex(of: true))
    let lines = model.tooltipLines(at: breakIndex + 1, timeZone: utc)
    XCTAssertTrue(lines.contains("Sources changed since the previous scan"))
    XCTAssertTrue(lines[1].hasPrefix("Total $"))
    XCTAssertFalse(model.tooltipLines(at: 0, timeZone: utc).contains("Sources changed since the previous scan"))
    XCTAssertEqual(model.tooltipLines(at: 9_999, timeZone: utc), [])
    let summary = model.summary(timeZone: utc, grouping: .asset)
    XCTAssertTrue(summary.contains("stacked by asset"))
    XCTAssertTrue(summary.contains("Sources changed once"))
  }

  // MARK: What changed

  func testWaterfallStepsAddUpToTheLatestTotal() throws {
    let outcome = WhatChangedModel.make(
      runs: ChartFixture.runs(), context: nil, maximumCoinBars: 20)
    guard case .ready(let waterfall) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(waterfall.bars.first?.kind, .start)
    XCTAssertEqual(waterfall.bars.last?.kind, .end)
    var running = waterfall.startTotal
    for bar in waterfall.coinBars {
      XCTAssertEqual(bar.low, min(running, running + bar.value), accuracy: 1e-6)
      XCTAssertEqual(bar.high, max(running, running + bar.value), accuracy: 1e-6)
      running += bar.value
      XCTAssertEqual(bar.level, running, accuracy: 1e-6)
    }
    XCTAssertEqual(running, waterfall.endTotal, accuracy: 1e-6)
    XCTAssertEqual(waterfall.bars.first?.runID, waterfall.previousRunID)
    XCTAssertEqual(waterfall.bars.last?.runID, waterfall.latestRunID)
    // Largest move first.
    let sizes = waterfall.coinBars.map { abs($0.value) }
    XCTAssertEqual(sizes, sizes.sorted(by: >))
  }

  func testWaterfallEffectsAddUpToTheChange() throws {
    guard
      case .ready(let waterfall) = WhatChangedModel.make(
        runs: ChartFixture.runs(), context: nil, maximumCoinBars: 20)
    else { return XCTFail("not ready") }
    XCTAssertEqual(
      waterfall.priceEffectUsd + waterfall.amountEffectUsd + waterfall.valuationGapUsd,
      waterfall.change, accuracy: 1e-6)
    XCTAssertGreaterThan(abs(waterfall.priceEffectUsd), 0)
    XCTAssertGreaterThan(abs(waterfall.amountEffectUsd), 0, "Base received 0.0094 ETH")
  }

  func testFoldedStepsKeepTheSumAndCountTheCoins() throws {
    guard
      case .ready(let all) = WhatChangedModel.make(
        runs: ChartFixture.runs(), context: nil, maximumCoinBars: 20),
      case .ready(let folded) = WhatChangedModel.make(
        runs: ChartFixture.runs(), context: nil, maximumCoinBars: 4)
    else { return XCTFail("not ready") }
    XCTAssertEqual(folded.coinBars.count, 4)
    let other = try XCTUnwrap(folded.coinBars.last)
    XCTAssertEqual(other.label, "Other")
    XCTAssertNil(other.coinKey)
    XCTAssertFalse(other.isSelectable, "a fold of several coins selects nothing")
    XCTAssertTrue(folded.bars.first?.isSelectable ?? false, "a total selects its scan")
    XCTAssertTrue(folded.coinBars.first?.isSelectable ?? false)
    XCTAssertEqual(other.coinCount, all.coinBars.count - 3)
    XCTAssertEqual(
      folded.coinBars.map(\.value).reduce(0, +), all.coinBars.map(\.value).reduce(0, +),
      accuracy: 1e-6)
    XCTAssertEqual(folded.bars.last?.level ?? 0, folded.endTotal, accuracy: 1e-6)
  }

  func testWaterfallRefusesToCompareDifferentSources() {
    // The wallet "Savings" appears between these two scans.
    let runs = [ChartFixture.run(day: 19), ChartFixture.run(day: 20, hour: 0)]
    XCTAssertEqual(WhatChangedModel.make(runs: runs, context: nil, maximumCoinBars: 7), .notComparable)
    XCTAssertEqual(
      WhatChangedModel.notComparableTitle,
      "Your sources changed since the last scan, so this compares different things.")
  }

  func testWaterfallNeedsTwoScansAndNoticesNothingChanged() {
    XCTAssertEqual(
      WhatChangedModel.make(runs: [ChartFixture.run(day: 5)], context: nil, maximumCoinBars: 7),
      .notEnoughScans)
    var twin = ChartFixture.run(day: 30)
    twin.id = UUID()
    twin.generatedAt = twin.generatedAt.addingTimeInterval(600)
    let outcome = WhatChangedModel.make(
      runs: [ChartFixture.run(day: 30), twin], context: nil, maximumCoinBars: 7)
    guard case .unchanged(let waterfall) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(waterfall.change, 0, accuracy: 1e-9)
    XCTAssertTrue(WhatChangedModel.headline(waterfall, timeZone: utc).hasPrefix("No change since"))
  }

  func testWaterfallComparesOnlyTheLatestTwoScansWhateverTheOrder() {
    var runs = ChartFixture.runs()
    runs.reverse()
    guard case .ready(let waterfall) = WhatChangedModel.make(runs: runs, context: nil, maximumCoinBars: 7)
    else { return XCTFail("not ready") }
    XCTAssertEqual(waterfall.latestDate, ChartFixture.scanDate(day: 41))
    XCTAssertEqual(waterfall.previousDate, ChartFixture.scanDate(day: 40, hour: 10))
  }

  func testWaterfallAxisIsZeroBasedUnlessEverythingSitsInANarrowBand() {
    let narrow = WhatChangedModel.axis(levels: [58_809, 59_291, 59_191, 59_050])
    XCTAssertFalse(narrow.isZeroBased)
    XCTAssertLessThan(narrow.low, 58_809)
    XCTAssertGreaterThan(narrow.low, 50_000)
    XCTAssertGreaterThanOrEqual(narrow.high, 59_291)
    let wide = WhatChangedModel.axis(levels: [100, 1_000, 1_100])
    XCTAssertTrue(wide.isZeroBased)
    XCTAssertEqual(wide.low, 0)
    XCTAssertGreaterThan(wide.high, 1_100)
    XCTAssertTrue(WhatChangedModel.axis(levels: []).isZeroBased)
    XCTAssertTrue(WhatChangedModel.axis(levels: [0, 0]).isZeroBased)
  }

  func testWaterfallLevelsIgnoreTheZeroOfATotalBar() throws {
    guard
      case .ready(let waterfall) = WhatChangedModel.make(
        runs: ChartFixture.runs(), context: nil, maximumCoinBars: 7)
    else { return XCTFail("not ready") }
    XCTAssertFalse(WhatChangedModel.levels(of: waterfall).contains(0))
    XCTAssertFalse(WhatChangedModel.axis(levels: WhatChangedModel.levels(of: waterfall)).isZeroBased == true)
  }

  func testWaterfallWords() throws {
    guard
      case .ready(let waterfall) = WhatChangedModel.make(
        runs: ChartFixture.runs(), context: nil, maximumCoinBars: 7)
    else { return XCTFail("not ready") }
    let headline = WhatChangedModel.headline(waterfall, timeZone: utc)
    XCTAssertTrue(headline.hasPrefix(waterfall.change > 0 ? "Up $" : "Down $"), headline)
    XCTAssertTrue(headline.contains("since Nov 3") || headline.contains("since 3 Nov"), headline)
    let eth = try XCTUnwrap(waterfall.coinBars.first { $0.coinKey == "ETH" })
    let lines = WhatChangedModel.tooltipLines(eth, waterfall: waterfall, timeZone: utc)
    XCTAssertTrue(lines[0].hasPrefix("ETH "))
    XCTAssertTrue(lines.contains { $0.hasPrefix("Price ") })
    XCTAssertTrue(lines.contains { $0.hasPrefix("Coins in or out ") })
    XCTAssertTrue(WhatChangedModel.summary(waterfall, timeZone: utc).contains("Price moves"))
  }

  // MARK: Slope

  func testSlopePicksTheOldestComparableScanInTheLastThirtyDays() throws {
    let runs = ChartFixture.runs()
    let pair = try XCTUnwrap(SlopeModel.choosePair(runs: runs, context: nil))
    XCTAssertEqual(pair.newer.generatedAt, ChartFixture.scanDate(day: 41))
    // Day 11 is the first inside the window; scans before day 20 read other
    // sources, so the oldest comparable one is the first scan of day 20.
    XCTAssertEqual(pair.older.generatedAt, ChartFixture.scanDate(day: 20))
    XCTAssertTrue(PortfolioAnalytics.runsShareSources(pair.older, pair.newer))
  }

  func testSlopeFallsBackToThePreviousScan() throws {
    // Only a scan from 45 days ago: nothing in the window, so the previous one.
    let old = ChartFixture.run(day: 0)
    let latest = ChartFixture.run(day: 41)
    let pair = try XCTUnwrap(SlopeModel.choosePair(runs: [latest, old], context: nil))
    XCTAssertEqual(pair.older.id, old.id)
    // Sources differ everywhere: the closest scan, flagged by the model.
    let near = ChartFixture.run(day: 19)
    let differing = [ChartFixture.run(day: 15), near, ChartFixture.run(day: 20, hour: 0)]
    let second = try XCTUnwrap(SlopeModel.choosePair(runs: differing, context: nil))
    XCTAssertEqual(second.older.id, near.id)
    XCTAssertNil(SlopeModel.choosePair(runs: [latest], context: nil))
    XCTAssertNil(SlopeModel.choosePair(runs: [], context: nil))
  }

  func testSlopeRowsPlaceEnteredAndLeftCoinsBelowTheDivider() throws {
    let pair = try XCTUnwrap(SlopeModel.choosePair(runs: ChartFixture.runs(), context: nil))
    let model = SlopeModel.make(
      older: pair.older, newer: pair.newer, context: nil, desiredLimit: 8, maximumSlots: 30)
    XCTAssertFalse(model.sourcesDiffer)
    let uni = try XCTUnwrap(model.rows.first { $0.id == "UNI" })
    XCTAssertTrue(uni.isGone)
    XCTAssertNil(uni.newerRank)
    XCTAssertTrue(uni.rightOutside)
    XCTAssertGreaterThan(uni.rightSlot, model.rankedSlots - 1)
    let op = try XCTUnwrap(model.rows.first { $0.id == "OP" })
    XCTAssertTrue(op.isNew)
    XCTAssertTrue(op.leftOutside)
    XCTAssertEqual(SlopeModel.movement(op), "new")
    XCTAssertEqual(SlopeModel.movement(uni), "out")
    XCTAssertTrue(model.hasUnrankedRows)

    // LINK overtook ATOM: one place up, and ATOM one place down.
    let link = try XCTUnwrap(model.rows.first { $0.id == "LINK" })
    let atom = try XCTUnwrap(model.rows.first { $0.id == "ATOM" })
    XCTAssertEqual(link.placesGained, 1)
    XCTAssertEqual(atom.placesGained, -1)
    XCTAssertEqual(SlopeModel.movement(link), "\u{25B2}1")
    XCTAssertEqual(SlopeModel.movement(atom), "\u{25BC}1")
    XCTAssertEqual(SlopeModel.spokenMovement(link), "up 1 place")
    XCTAssertEqual(SlopeModel.spokenMovement(atom), "down 1 place")
  }

  func testSlopeSlotsNeverCollideAndFitTheHeight() throws {
    let pair = try XCTUnwrap(SlopeModel.choosePair(runs: ChartFixture.runs(), context: nil))
    for maximum in [30, 14, 9, 6] {
      let model = SlopeModel.make(
        older: pair.older, newer: pair.newer, context: nil, desiredLimit: 8,
        maximumSlots: maximum)
      var left: Set<Int> = []
      var right: Set<Int> = []
      for row in model.rows {
        XCTAssertTrue(left.insert(row.leftSlot).inserted, "left slot \(row.leftSlot) \(maximum)")
        XCTAssertTrue(right.insert(row.rightSlot).inserted, "right slot \(row.rightSlot) \(maximum)")
        XCTAssertLessThan(row.leftSlot, model.slotCount)
        XCTAssertLessThan(row.rightSlot, model.slotCount)
      }
      // The limit only shrinks while it can: never below three ranks.
      if model.rankedSlots > 3 { XCTAssertLessThanOrEqual(model.slotCount, maximum, "max \(maximum)") }
    }
  }

  func testSlopeSaysWhenTheScansReadDifferentSources() {
    let model = SlopeModel.make(
      older: ChartFixture.run(day: 19), newer: ChartFixture.run(day: 20, hour: 0), context: nil,
      desiredLimit: 8, maximumSlots: 20)
    XCTAssertTrue(model.sourcesDiffer)
    XCTAssertTrue(model.summary(timeZone: utc).contains("different sources"))
  }

  func testSlopeCopy() throws {
    let pair = try XCTUnwrap(SlopeModel.choosePair(runs: ChartFixture.runs(), context: nil))
    let model = SlopeModel.make(
      older: pair.older, newer: pair.newer, context: nil, desiredLimit: 8, maximumSlots: 30)
    let link = try XCTUnwrap(model.rows.first { $0.id == "LINK" })
    let lines = model.tooltipLines(for: link)
    XCTAssertEqual(lines[0], "LINK")
    XCTAssertEqual(lines[1], "Rank 5 to 4, up 1 place")
    XCTAssertTrue(lines[2].contains(" to $"))
    let summary = model.summary(timeZone: utc)
    XCTAssertTrue(summary.contains("New: OP"))
    XCTAssertTrue(summary.contains("No longer ranked: UNI"))
  }

  // MARK: Concentration

  func testGaugeGivesEachBandAThirdOfTheDial() {
    XCTAssertEqual(ConcentrationModel.gaugePosition(herfindahl: 0), 0)
    XCTAssertEqual(ConcentrationModel.gaugePosition(herfindahl: 0.15), 1.0 / 3, accuracy: 1e-9)
    XCTAssertEqual(ConcentrationModel.gaugePosition(herfindahl: 0.25), 2.0 / 3, accuracy: 1e-9)
    XCTAssertEqual(ConcentrationModel.gaugePosition(herfindahl: 1), 1, accuracy: 1e-9)
    XCTAssertEqual(ConcentrationModel.gaugePosition(herfindahl: 5), 1, accuracy: 1e-9)
    XCTAssertEqual(ConcentrationModel.gaugePosition(herfindahl: .nan), 0)
    var previous = -1.0
    for step in 0...100 {
      let position = ConcentrationModel.gaugePosition(herfindahl: Double(step) / 100)
      XCTAssertGreaterThanOrEqual(position, previous)
      previous = position
    }
  }

  func testConcentrationReadingForThePortfolio() {
    let model = ConcentrationModel(holdings: ChartFixture.latestHoldings, grouping: .asset)
    XCTAssertTrue(model.hasValue)
    let top = HistoryChartFormat.percent(model.concentration.topShare)
    let effective = ConcentrationModel.effectiveText(model.concentration.effectiveHoldings)
    XCTAssertEqual(
      model.reading,
      "\(top) is in one coin. Your portfolio behaves like \(effective) equal holdings.")
    XCTAssertEqual(model.concentration.leaders.count, 3)
    XCTAssertEqual(model.concentration.leaders.first?.label, "BTC")
    XCTAssertTrue(model.spokenSummary.contains("Largest: BTC"))
    XCTAssertEqual(model.selection(for: model.concentration.leaders[0]), .coin("BTC"))
  }

  func testConcentrationReadingForOtherGroupingsAndEdges() {
    let network = ConcentrationModel(holdings: ChartFixture.latestHoldings, grouping: .network)
    XCTAssertTrue(network.reading.contains("is in one network."))
    XCTAssertTrue(network.reading.hasSuffix("equal networks."))
    XCTAssertEqual(
      network.selection(for: network.concentration.leaders[0]),
      .slice(grouping: .network, key: network.concentration.leaders[0].id))
    let single = ConcentrationModel(
      holdings: ChartFixture.latestHoldings.filter { $0.symbol == "BTC" && $0.walletLabel == "Cold storage" },
      grouping: .asset)
    XCTAssertEqual(single.reading, "All of it is in one coin.")
    XCTAssertEqual(single.levelTitle, "Concentrated")
    let none = ConcentrationModel(holdings: [], grouping: .asset)
    XCTAssertFalse(none.hasValue)
    XCTAssertEqual(none.levelTitle, "No priced value")
    XCTAssertEqual(ConcentrationModel.effectiveText(2.64), "2.6")
    XCTAssertEqual(ConcentrationModel.effectiveText(11.4), "11")
  }

  func testConcentrationIgnoresUnpricedHoldings() {
    let with = ConcentrationModel(
      holdings: ChartFixture.holdings(day: 41, includeUnpriced: true), grouping: .asset)
    let without = ConcentrationModel(holdings: ChartFixture.holdings(day: 41), grouping: .asset)
    XCTAssertEqual(with.concentration.topShare, without.concentration.topShare, accuracy: 1e-12)
    XCTAssertEqual(with.reading, without.reading)
  }
}
