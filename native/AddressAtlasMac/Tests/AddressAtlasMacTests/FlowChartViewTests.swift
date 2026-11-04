import AddressAtlasCore
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

@MainActor
final class FlowChartViewTests: XCTestCase {
  private let full = CGSize(width: 640, height: 360)
  private let compactSize = CGSize(width: 320, height: 180)

  override func setUp() {
    super.setUp()
    // Money and shares read the same on every machine.
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private var fixtureFlow: FlowGraph { PortfolioAnalytics.flowGraph(ChartFixture.latestHoldings) }

  /// Forty coins spread over three wallets and two states.
  private func manyCoins() -> [TrackedAsset] {
    let addresses = [
      ChartFixture.evmAddress, ChartFixture.savingsAddress, "0x0000000000000000000000000000000000000003",
    ]
    return (0..<40).map { index in
      let value = 3_000 / Double(index + 1) + 20
      return TrackedAsset(
        id: "many-\(index)", address: addresses[index % 3], chainId: "ethereum",
        chainName: "Ethereum", family: .evm, symbol: "T\(index)", name: "Token \(index)",
        amount: value, priceUsd: 1, valueUsd: value, pricingStatus: .priced,
        source: index % 5 == 0 ? .staked : .erc20, walletLabel: "Wallet \(index % 3)")
    }
  }

  // MARK: Selection

  func testSelectionKeysFollowTheColumns() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    let source = layout.graph.nodes.first { $0.column == 0 }!
    let coin = layout.graph.nodes.first { $0.column == 1 && $0.key == "ETH" }!
    let state = layout.graph.nodes.first { $0.column == 2 && $0.key == "liquid" }!
    XCTAssertEqual(
      FlowChartModel.selection(for: source), .slice(grouping: .source, key: source.key))
    XCTAssertEqual(FlowChartModel.selection(for: coin), .coin("ETH"))
    XCTAssertEqual(
      FlowChartModel.selection(for: state), .slice(grouping: .state, key: "liquid"))
  }

  func testLinksSelectTheirCoin() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    for link in layout.result.links {
      let selection = FlowChartModel.selection(for: link, in: layout)
      let coin = [layout.node(link.from), layout.node(link.to)].compactMap { $0 }.first {
        $0.column == 1
      }
      XCTAssertEqual(selection, coin.flatMap { FlowChartModel.selection(for: $0) }, link.id)
    }
  }

  func testOtherNodesCannotBeSelected() {
    let layout = FlowChartModel.layout(
      flow: PortfolioAnalytics.flowGraph(manyCoins()), size: compactSize, compact: true)
    let others = layout.graph.nodes.filter(\.isOther)
    XCTAssertFalse(others.isEmpty)
    for node in others {
      XCTAssertNil(FlowChartModel.selection(for: node))
      XCTAssertNil(FlowChartModel.selection(for: .node(node.id), in: layout))
    }
    let otherCoin = layout.graph.nodes.first { $0.isOther && $0.column == 1 }
    XCTAssertEqual(otherCoin?.label, "Other coins")
    for link in layout.result.links where link.to == otherCoin?.id {
      XCTAssertNil(FlowChartModel.selection(for: link, in: layout))
    }
  }

  // MARK: Folding

  func testFullDensityKeepsSmallStatesWhenTheyFit() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    let states = layout.graph.nodes.filter { $0.column == 2 }.map(\.key)
    XCTAssertTrue(states.contains("unbonding"))
    XCTAssertTrue(states.contains("rewards"))
    XCTAssertFalse(layout.graph.nodes.contains { $0.isOther })
  }

  func testCompactDensityFoldsTinyNodesIntoOther() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: compactSize, compact: true)
    let states = layout.graph.nodes.filter { $0.column == 2 }
    XCTAssertTrue(states.contains { $0.isOther })
    XCTAssertFalse(states.contains { $0.key == "rewards" })
    // One tiny node alone is not folded: "Other" would say less than the node.
    let single = FlowChartModel.foldedGraph(
      SankeyGraph(
        nodes: [
          .init(id: "coin:A", column: 1, value: 90, label: "A", key: "A", isOther: false),
          .init(id: "coin:B", column: 1, value: 9, label: "B", key: "B", isOther: false),
          .init(id: "coin:C", column: 1, value: 1, label: "C", key: "C", isOther: false),
        ], edges: []),
      capacity: 10, tinyShare: 0.03)
    XCTAssertEqual(single.nodes.count, 3)
  }

  func testFoldingKeepsEveryColumnTotal() {
    let flow = PortfolioAnalytics.flowGraph(manyCoins())
    for (size, compact) in [(full, false), (compactSize, true)] {
      let layout = FlowChartModel.layout(flow: flow, size: size, compact: compact)
      for column in 0...2 {
        let total = layout.graph.nodes(inColumn: column).map(\.value).reduce(0, +)
        XCTAssertEqual(total, flow.totalValueUsd, accuracy: 0.01, "column \(column)")
      }
      XCTAssertLessThanOrEqual(
        layout.graph.nodes(inColumn: 1).count, layout.config.nodeCapacity)
    }
  }

  func testManyCoinsLayOutWithoutOverlap() {
    let flow = PortfolioAnalytics.flowGraph(manyCoins())
    for (size, compact) in [(full, false), (compactSize, true)] {
      let layout = FlowChartModel.layout(flow: flow, size: size, compact: compact)
      for column in 0...2 {
        let nodes = layout.result.nodes.filter { $0.column == column }.sorted {
          $0.rect.minY < $1.rect.minY
        }
        for (upper, lower) in zip(nodes, nodes.dropFirst()) {
          XCTAssertLessThanOrEqual(upper.rect.maxY, lower.rect.minY + 0.001)
        }
        for node in nodes {
          XCTAssertGreaterThanOrEqual(
            node.rect.height, layout.config.minimumNodeHeight - 0.001, node.id)
        }
      }
    }
  }

  // MARK: Hit testing

  func testNodeCentresAndLinkMiddlesAreHit() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    for box in layout.result.nodes {
      XCTAssertEqual(
        FlowChartModel.hitTest(CGPoint(x: box.rect.midX, y: box.rect.midY), layout: layout),
        .node(box.id))
    }
    for link in layout.result.links where link.thickness >= 3 {
      let x = (link.x0 + link.x1) / 2
      guard let top = FlowChartModel.linkTop(link, atX: x) else {
        return XCTFail("no top for \(link.id)")
      }
      let point = CGPoint(x: x, y: top + link.thickness / 2)
      let target = FlowChartModel.hitTest(point, layout: layout)
      // Where ribbons cross, the thinnest one under the pointer wins.
      let covering = FlowChartModel.linksCovering(point, layout: layout)
      XCTAssertTrue(covering.contains { $0.id == link.id }, link.id)
      XCTAssertEqual(target, covering.first.map { .link($0.id) }, link.id)
      if covering.count == 1 { XCTAssertEqual(target, .link(link.id)) }
    }
    XCTAssertNil(FlowChartModel.hitTest(CGPoint(x: 320, y: -20), layout: layout))
  }

  func testSourceAndStateLabelsCountAsTheirNode() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    let source = layout.result.nodes.first { $0.column == 0 }!
    XCTAssertEqual(
      FlowChartModel.hitTest(CGPoint(x: 20, y: source.rect.midY), layout: layout),
      .node(source.id))
    let state = layout.result.nodes.first { $0.column == 2 }!
    XCTAssertEqual(
      FlowChartModel.hitTest(CGPoint(x: full.width - 10, y: state.rect.midY), layout: layout),
      .node(state.id))
  }

  func testLinkTopFollowsTheRibbonEnds() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    for link in layout.result.links {
      XCTAssertEqual(FlowChartModel.linkTop(link, atX: link.x0) ?? -1, link.y0, accuracy: 0.01)
      XCTAssertEqual(FlowChartModel.linkTop(link, atX: link.x1) ?? -1, link.y1, accuracy: 0.01)
      XCTAssertNil(FlowChartModel.linkTop(link, atX: link.x0 - 1))
      let middle = FlowChartModel.linkTop(link, atX: (link.x0 + link.x1) / 2) ?? -1
      XCTAssertEqual(middle, (link.y0 + link.y1) / 2, accuracy: 0.01)
    }
  }

  func testHoveringANodeLightsItsLinksAndNeighbours() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    let eth = layout.graph.nodes.first { $0.id == "coin:ETH" }!
    let links = FlowChartModel.highlightedLinks(for: .node(eth.id), in: layout)
    XCTAssertEqual(
      links, Set(layout.result.links.filter { $0.from == eth.id || $0.to == eth.id }.map(\.id)))
    let nodes = FlowChartModel.highlightedNodes(for: .node(eth.id), in: layout)
    XCTAssertTrue(nodes.contains("source:wallet:evm:\(ChartFixture.evmAddress)") || nodes.count > 1)
    XCTAssertTrue(nodes.contains(eth.id))
  }

  // MARK: Words

  func testUnpricedNoteIsSingularOrPlural() {
    XCTAssertNil(FlowChartModel.unpricedNote(count: 0))
    XCTAssertEqual(
      FlowChartModel.unpricedNote(count: 1), "1 holding has no price and is not shown.")
    XCTAssertEqual(
      FlowChartModel.unpricedNote(count: 2), "2 holdings have no price and are not shown.")
  }

  func testSummaryNamesTheTotalAndTheLargestCoin() {
    let flow = fixtureFlow
    let summary = FlowChartModel.summary(flow: flow)
    XCTAssertTrue(summary.contains("Flow of $"), summary)
    XCTAssertTrue(summary.contains("Largest coin: BTC"), summary)
  }

  func testTooltipsReadAsSentences() {
    let layout = FlowChartModel.layout(flow: fixtureFlow, size: full, compact: false)
    let lines = FlowChartModel.tooltipLines(for: .node("coin:ETH"), in: layout)
    XCTAssertEqual(lines.first, "ETH")
    XCTAssertTrue(lines.last?.contains("%") == true)
    let link = layout.result.links.first { $0.to == "coin:ETH" }!
    let linkLines = FlowChartModel.tooltipLines(for: .link(link.id), in: layout)
    XCTAssertTrue(linkLines.first?.contains("\u{2192} ETH") == true)
    XCTAssertTrue(
      FlowChartModel.accessibilityLabel(for: layout.node("coin:ETH")!, in: layout)
        .hasPrefix("ETH, coin, $"))
  }

  // MARK: Rendering

  func testEmptyAndUnpricedInputsRenderAMessage() throws {
    let tokens = AtlasThemeTokens(theme: .chainColors, variant: .light)
    let empty = PortfolioChartInput(holdings: [])
    _ = try ChartRenderTests.renderImage(
      AnyView(FlowChartView(input: empty)), tokens: tokens, colorScheme: .light, size: full)
    let unpriced = ChartFixture.holdings(day: 41, includeUnpriced: true).filter {
      $0.pricingStatus != .priced
    }
    _ = try ChartRenderTests.renderImage(
      AnyView(FlowChartView(input: PortfolioChartInput(holdings: unpriced))), tokens: tokens,
      colorScheme: .light, size: full)
  }

  func testManyCoinsAndUnpricedRenderInEveryDensity() throws {
    var holdings = manyCoins()
    holdings.append(contentsOf: ChartFixture.holdings(day: 41, includeUnpriced: true).filter {
      $0.pricingStatus != .priced
    })
    for density in [PortfolioChartDensity.full, .compact] {
      for theme in AtlasThemeID.allCases {
        let variant: AtlasAppearanceVariant = theme == .acid ? .dark : .light
        let tokens = AtlasThemeTokens(theme: theme, variant: variant)
        let input = PortfolioChartInput(holdings: holdings, density: density)
        let size = density == .full ? CGSize(width: 640, height: 400) : CGSize(width: 320, height: 200)
        let image = try ChartRenderTests.renderImage(
          AnyView(FlowChartView(input: input)), tokens: tokens,
          colorScheme: variant.isDark ? .dark : .light, size: size)
        XCTAssertGreaterThan(ChartRenderTests.distinctColors(in: image), 8)
        if let directory = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_DIR"],
          ProcessInfo.processInfo.environment["ATLAS_WRITE_SCREENSHOTS"] == "1"
        {
          let name = "flow-many-\(theme.rawValue)-\(density == .full ? "full" : "compact").png"
          let folder = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try ChartRenderTests.pngData(image).write(to: folder.appendingPathComponent(name))
        }
      }
    }
  }
}
