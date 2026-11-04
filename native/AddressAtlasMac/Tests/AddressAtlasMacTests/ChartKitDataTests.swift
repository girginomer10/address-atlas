import AddressAtlasCore
import XCTest

@testable import AddressAtlasMac

/// What the part-C1 views are given: slices from `PortfolioAnalytics`, their
/// colours, selections, folding, wording, and the second level.
final class ChartKitDataTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  override func tearDown() {
    unsetenv("ADDRESS_ATLAS_UI_LOCALE")
    super.tearDown()
  }

  private func input(
    _ holdings: [TrackedAsset] = ChartKitFixtures.portfolio(),
    grouping: PortfolioGrouping = .asset,
    coinKey: String? = nil,
    density: PortfolioChartDensity = .full
  ) -> PortfolioChartInput {
    PortfolioChartInput(holdings: holdings, grouping: grouping, coinKey: coinKey, density: density)
  }

  // MARK: Slices

  func testAssetSlicesComeFromAnalyticsLargestFirst() {
    let data = ChartKitData(input: input())
    XCTAssertEqual(data.slices.map(\.label), ["BTC", "ETH", "SOL", "ATOM", "USDC"])
    XCTAssertEqual(data.totalValueUsd, 49_211.51, accuracy: 0.01)
    XCTAssertEqual(data.slices.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
    XCTAssertEqual(data.slices[0].valueUsd, 27_980.10, accuracy: 0.01)
    XCTAssertEqual(data.slices[0].share, 0.5685, accuracy: 0.0001)
    XCTAssertFalse(data.isEmpty)
    XCTAssertEqual(data.unpricedHoldingCount, 1)
    XCTAssertEqual(data.unpricedRows.map(\.symbol), ["ZKT"])
    XCTAssertEqual(data.unpricedRows.first?.name, "Zeta Kite Token")
  }

  func testSlicesReportTheSelectionTheContractDescribes() {
    let assets = ChartKitData(input: input())
    XCTAssertEqual(assets.slices[0].selection, .coin("BTC"))
    let network = ChartKitData(input: input(grouping: .network))
    XCTAssertTrue(
      network.slices.allSatisfy {
        $0.selection == .slice(grouping: .network, key: $0.key)
      })
    let state = ChartKitData(input: input(grouping: .state))
    XCTAssertEqual(
      Set(state.slices.map(\.key)), ["liquid", "staked", "unbonding", "rewards", "onExchange"])
    XCTAssertTrue(
      state.slices.allSatisfy { $0.selection == .slice(grouping: .state, key: $0.key) })
  }

  func testColourKeysFollowTheGrouping() {
    XCTAssertEqual(ChartKitData(input: input()).slices[0].color, .asset("BTC"))
    let state = ChartKitData(input: input(grouping: .state))
    XCTAssertEqual(state.slices.first { $0.key == "staked" }?.color, .state(.staked))
    let kind = ChartKitData(input: input(grouping: .kind))
    XCTAssertEqual(kind.slices.first { $0.key == "stablecoin" }?.color, .kind(.stablecoin))
    let source = ChartKitData(input: input(grouping: .source))
    XCTAssertEqual(source.slices.map(\.color), source.slices.indices.map { .index($0) })
  }

  func testEveryColourKeyResolvesInEveryTheme() {
    let data = ChartKitData(input: input())
    for grouping in PortfolioGrouping.allCases {
      let slices = ChartKitData(input: input(grouping: grouping)).slices
      for theme in AtlasThemeID.allCases {
        let tokens = AtlasThemeTokens(theme: theme, variant: .light)
        for slice in slices {
          let colour = tokens.chartKitRGB(slice.color)
          XCTAssertTrue(colour.red.isFinite && colour.red >= 0 && colour.red <= 1)
        }
        // Text on any block is readable.
        for slice in data.slices {
          let block = tokens.chartKitRGB(slice.color)
          XCTAssertGreaterThanOrEqual(
            block.contrast(with: tokens.chartKitInk(on: block)), 4.5, "\(theme) \(slice.label)")
        }
      }
    }
  }

  func testNoTwoSlicesOfOneChartShareAColour() {
    // Riso prints Bitcoin and Cosmos in one pink and Ether and USD Coin in one blue.
    let tokens = AtlasThemeTokens(theme: .riso, variant: .light)
    let slices = ChartKitData(input: input()).drawable
    XCTAssertEqual(tokens.chartKitRGB(slices[0].color), tokens.chartKitRGB(slices[3].color))
    let colors = tokens.chartKitColors(for: slices)
    XCTAssertEqual(colors.count, slices.count)
    XCTAssertEqual(Set(colors.values).count, slices.count)
    // The first of two alike keeps the theme's colour; the second is a tone of it.
    XCTAssertEqual(colors[slices[0].id], tokens.chartKitRGB(slices[0].color))
    XCTAssertNotEqual(colors[slices[3].id], tokens.chartKitRGB(slices[3].color))
    // Every theme gives every chart distinct colours, and the answer does not change.
    for theme in AtlasThemeID.allCases {
      let themed = AtlasThemeTokens(theme: theme, variant: .dark)
      for grouping in PortfolioGrouping.allCases {
        let all = ChartKitData(input: input(grouping: grouping)).drawable
        let assigned = themed.chartKitColors(for: all)
        XCTAssertEqual(Set(assigned.values).count, all.count, "\(theme) \(grouping)")
        XCTAssertEqual(assigned, themed.chartKitColors(for: all))
      }
    }
  }

  func testNetworkColoursFindAnExchangeByItsName() {
    let tokens = AtlasThemeTokens(theme: .chainColors, variant: .light)
    XCTAssertEqual(
      tokens.chartKitRGB(.network(key: "kraken", label: "Kraken")), tokens.chart.network("kraken"))
    // An unknown chain id falls back to a name match before the stable pick.
    XCTAssertEqual(
      tokens.chartKitRGB(.network(key: "exchange-1", label: "Base")), tokens.chart.network("base"))
  }

  func testAssetSlicesKnowTheCoinsName() {
    let data = ChartKitData(input: input())
    XCTAssertEqual(data.slices[0].spokenName, "Bitcoin")
    XCTAssertEqual(data.slices[0].subtitle, "Bitcoin")
    XCTAssertEqual(data.slices[0].accessibilityLabel, "Bitcoin, 57 percent, $27,980")
    // A network slice has no coin name: it is read as it is written.
    let network = ChartKitData(input: input(grouping: .network))
    XCTAssertEqual(network.slices[0].spokenName, network.slices[0].label)
    XCTAssertNil(network.slices[0].subtitle)
  }

  func testZeroValueSlicesAreListedButNotDrawn() {
    var holdings = ChartKitFixtures.portfolio()
    holdings.append(
      ChartKitFixtures.wallet(
        "DUST", name: "Dust", amount: 0, price: 1, family: .evm, chainId: "ethereum",
        chainName: "Ethereum", address: ChartKitFixtures.evmAddress, label: "Main"))
    let data = ChartKitData(input: input(holdings))
    XCTAssertTrue(data.slices.contains { $0.label == "DUST" })
    XCTAssertFalse(data.drawable.contains { $0.label == "DUST" })
  }

  // MARK: Empty and unpriced

  func testNothingPricedIsEmptyAndSaysSo() {
    let none = ChartKitData(input: input([]))
    XCTAssertTrue(none.isEmpty)
    XCTAssertEqual(none.summary(viewName: "Map"), "Map. No priced holdings yet.")

    let unpricedOnly = ChartKitFixtures.portfolio().filter { $0.symbol == "ZKT" }
    let data = ChartKitData(input: input(unpricedOnly))
    XCTAssertTrue(data.isEmpty)
    XCTAssertEqual(data.unpricedHoldingCount, 1)
    XCTAssertEqual(
      data.summary(viewName: "Ring"),
      "Ring. No priced holdings yet. 1 holding has no price and isn't in the total.")
  }

  func testUnpricedNoteIsPlainAndSingularOrPlural() {
    XCTAssertEqual(
      ChartKitFormat.unpricedNote(count: 1), "1 holding has no price and isn't in the total.")
    XCTAssertEqual(
      ChartKitFormat.unpricedNote(count: 3), "3 holdings have no price and aren't in the total.")
    XCTAssertEqual(ChartKitFormat.unpricedShort(count: 3), "3 unpriced")
  }

  func testUnpricedHoldingsOfOneCoinShareARow() {
    var holdings = ChartKitFixtures.portfolio()
    holdings.append(
      ChartKitFixtures.wallet(
        "ZKT", name: "Zeta Kite Token", amount: 5, price: nil, source: .erc20, family: .evm,
        chainId: "base", chainName: "Base", address: ChartKitFixtures.evmAddress, label: "Main"))
    let data = ChartKitData(input: input(holdings))
    XCTAssertEqual(data.unpricedHoldingCount, 2)
    XCTAssertEqual(data.unpricedRows.count, 1)
    XCTAssertEqual(data.unpricedRows[0].holdingCount, 2)
  }

  func testSummaryNamesTheTotalAndTheGrouping() {
    let data = ChartKitData(input: input())
    XCTAssertEqual(
      data.summary(viewName: "Map"),
      "Map of holdings by asset. Total $49,212 across 5 assets. 1 holding has no price and isn't in the total."
    )
    XCTAssertTrue(
      ChartKitData(input: input(grouping: .state)).summary(viewName: "Ring").contains("by state"))
  }

  // MARK: Coin view

  func testASingleCoinIsSplitByNetworkInsteadOfBeingOneSlice() {
    let data = ChartKitData(
      input: input(ChartKitFixtures.ethOnly(), grouping: .asset, coinKey: "ETH"))
    XCTAssertEqual(data.grouping, .network)
    XCTAssertEqual(data.slices.map(\.label), ["Ethereum", "Base", "Kraken"])
    XCTAssertTrue(data.isCoinView)
    let state = ChartKitData(
      input: input(ChartKitFixtures.ethOnly(), grouping: .state, coinKey: "ETH"))
    XCTAssertEqual(state.grouping, .state)
  }

  // MARK: Second level

  func testSecondaryGroupingAddsInformation() {
    let holdings = ChartKitFixtures.portfolio()
    // Something is staked, so assets split by state.
    XCTAssertEqual(
      ChartKitData.secondaryGrouping(for: .asset, holdings: holdings, coinView: false), .state)
    // Nothing staked: liquid and exchange holdings split by network.
    let plain = holdings.filter { [.native, .exchange, .erc20].contains($0.source) }
    XCTAssertEqual(
      ChartKitData.secondaryGrouping(for: .asset, holdings: plain, coinView: false), .network)
    for grouping in [PortfolioGrouping.network, .source, .state, .kind] {
      XCTAssertEqual(
        ChartKitData.secondaryGrouping(for: grouping, holdings: holdings, coinView: false), .asset)
    }
    // On a coin's own screen a split by asset would be one slice.
    XCTAssertEqual(
      ChartKitData.secondaryGrouping(for: .network, holdings: holdings, coinView: true), .state)
    XCTAssertEqual(
      ChartKitData.secondaryGrouping(for: .state, holdings: holdings, coinView: true), .network)
  }

  func testAutomaticNestingSplitsAssetsByStateAndSumsToTheParent() {
    let data = ChartKitData(input: input(), nesting: .automatic)
    XCTAssertEqual(data.secondaryGrouping, .state)
    let atom = data.slices.first { $0.label == "ATOM" }!
    XCTAssertEqual(
      atom.children.map(\.key), ["staked", "unbonding", "liquid", "rewards"])
    XCTAssertEqual(
      atom.children.map(\.valueUsd).reduce(0, +), atom.valueUsd, accuracy: 1e-6)
    XCTAssertEqual(atom.children.map(\.shareOfParent).reduce(0, +), 1, accuracy: 1e-9)
    // A second-level arc about a state selects the coin it sits in.
    XCTAssertTrue(atom.children.allSatisfy { $0.selection == .coin("ATOM") })
    XCTAssertEqual(
      atom.children[0].accessibilityLabel(inside: atom),
      "Cosmos Hub, Staked, 4 percent, $1,904")
  }

  func testNestingByAnotherGroupingSelectsTheCoinForCoinArcs() {
    let data = ChartKitData(input: input(grouping: .network), nesting: .automatic)
    XCTAssertEqual(data.secondaryGrouping, .asset)
    let ethereum = data.slices.first { $0.key == "ethereum" }!
    XCTAssertTrue(ethereum.children.allSatisfy { $0.selection == .coin($0.key) })
    XCTAssertEqual(
      ethereum.children.map(\.valueUsd).reduce(0, +), ethereum.valueUsd, accuracy: 1e-6)
  }

  func testFixedNestingIgnoresAGroupingEqualToTheFirstLevel() {
    XCTAssertNil(ChartKitData(input: input(), nesting: .grouping(.asset)).secondaryGrouping)
    XCTAssertEqual(
      ChartKitData(input: input(), nesting: .grouping(.network)).secondaryGrouping, .network)
    XCTAssertNil(ChartKitData(input: input()).secondaryGrouping)
  }

  // MARK: Folding

  func testFoldingKeepsTheBigSlicesAndSumsTheRestIntoOther() {
    let data = ChartKitData(input: input(ChartKitFixtures.crowdedPortfolio()))
    XCTAssertGreaterThan(data.drawable.count, 30)
    let folded = data.folded(maxCount: 8, minShare: 0.02)
    XCTAssertLessThanOrEqual(folded.count, 9)
    let other = try? XCTUnwrap(folded.last)
    XCTAssertEqual(other?.label, "Other")
    XCTAssertEqual(other?.isOther, true)
    XCTAssertNil(other?.selection)
    XCTAssertEqual(
      folded.map(\.valueUsd).reduce(0, +), data.drawable.map(\.valueUsd).reduce(0, +),
      accuracy: 1e-6)
    XCTAssertEqual(folded.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
    // The five biggest always survive.
    XCTAssertEqual(
      Array(folded.prefix(5).map(\.id)), Array(data.drawable.prefix(5).map(\.id)))
    XCTAssertTrue(other?.accessibilityLabel.hasPrefix("Other, ") ?? false)
  }

  func testFoldingLeavesASmallPortfolioAloneAndNeverFoldsASingleSlice() {
    let data = ChartKitData(input: input())
    XCTAssertEqual(data.folded(maxCount: 8, minShare: 0.02).map(\.label), data.drawable.map(\.label))
    // A tail of exactly one slice stays as it is.
    let six = data.drawable
    XCTAssertEqual(
      ChartKitData.fold(six, grouping: .asset, maxCount: 4, minShare: 0.5, minimumKept: 4, ofParent: nil)
        .count, 5)
    let folded = ChartKitData.fold(
      six, grouping: .asset, maxCount: 3, minShare: 0.5, minimumKept: 3, ofParent: nil)
    XCTAssertEqual(folded.count, 4)
    XCTAssertEqual(folded.last?.label, "Other")
  }

  // MARK: Formatting

  func testPercentsAreWholeAndHonestAboutTinyShares() {
    XCTAssertEqual(ChartKitFormat.percent(0.5685), "57%")
    XCTAssertEqual(ChartKitFormat.percent(0.004), "<1%")
    XCTAssertEqual(ChartKitFormat.percent(0), "0%")
    XCTAssertEqual(ChartKitFormat.percent(1), "100%")
    XCTAssertEqual(ChartKitFormat.percent(.nan), "0%")
    XCTAssertEqual(ChartKitFormat.spokenPercent(0.5685), "57 percent")
    XCTAssertEqual(ChartKitFormat.spokenPercent(0.003), "less than 1 percent")
    XCTAssertEqual(ChartKitFormat.spokenPercent(0), "0 percent")
  }

  func testMoneyFollowsTheLocaleAndRoundsAsAsked() {
    XCTAssertEqual(ChartKitFormat.usd(27_980.1), "$27,980")
    XCTAssertEqual(ChartKitFormat.usd(27_980.1, .cents), "$27,980.10")
    XCTAssertEqual(ChartKitFormat.usd(27_980.1, .compact), "$28K")
    XCTAssertEqual(ChartKitFormat.usd(1_340_000, .compact), "$1.3M")
    XCTAssertEqual(ChartKitFormat.usd(.nan), "$0")

    setenv("ADDRESS_ATLAS_UI_LOCALE", "de_DE", 1)
    // German writes a (non-breaking) space before the sign.
    XCTAssertTrue(ChartKitFormat.percent(0.57).first?.isNumber ?? false)
    XCTAssertEqual(ChartKitFormat.percent(0.57).filter { !$0.isWhitespace }, "57%")
    XCTAssertNotEqual(ChartKitFormat.percent(0.57), "57%")
    XCTAssertTrue(ChartKitFormat.usd(27_980.1).contains("27.980"))
    setenv("ADDRESS_ATLAS_UI_LOCALE", "tr_TR", 1)
    XCTAssertEqual(ChartKitFormat.percent(0.57), "%57")
  }

  func testCountsAreSingularOrPluralPerGrouping() {
    XCTAssertEqual(ChartKitFormat.count(1, of: .asset), "1 asset")
    XCTAssertEqual(ChartKitFormat.count(5, of: .asset), "5 assets")
    XCTAssertEqual(ChartKitFormat.count(2, of: .source), "2 wallets and exchanges")
    XCTAssertEqual(ChartKitFormat.count(1, of: .kind), "1 type")
  }

  // MARK: Interaction

  func testInteractionStatePrefersHoverOverSelectionAndDimsTheRest() {
    var state = ChartKitInteractionState()
    XCTAssertFalse(state.isDimmed("a"))
    state.selectedID = "a"
    XCTAssertEqual(state.activeID, "a")
    XCTAssertTrue(state.isDimmed("b"))
    state.hoveredID = "b"
    XCTAssertEqual(state.activeID, "b")
    XCTAssertTrue(state.isDimmed("a"))
    XCTAssertFalse(state.isDimmed("b"))
    state.hoveredID = "a>x"
    XCTAssertTrue(state.isActive(slice: "a"))
    XCTAssertFalse(state.isActive(slice: "ab"))
  }
}
