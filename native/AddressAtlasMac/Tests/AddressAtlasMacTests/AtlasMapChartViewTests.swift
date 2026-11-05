import AddressAtlasCore
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

@MainActor
final class AtlasMapChartViewTests: XCTestCase {
  private let full = CGSize(width: 640, height: 360)
  private let compactSize = CGSize(width: 320, height: 180)

  override func setUp() {
    super.setUp()
    // Money and shares read the same on every machine.
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private func slice(_ key: String, _ value: Double, total: Double) -> AtlasMapSlice {
    AtlasMapSlice(key: key, label: key, value: value, share: value / total)
  }

  /// Holdings on four networks (Bitcoin, Ethereum, Kraken, Solana), each with
  /// at least 8% of the value: the shape that nests.
  private var nestingHoldings: [TrackedAsset] {
    let networks = ["bitcoin", "ethereum", "kraken", "solana"]
    return ChartFixture.latestHoldings.filter { networks.contains($0.chainId) }
  }

  /// Fifty tokens over three wallets, to force "Other".
  private func manyTokens() -> [TrackedAsset] {
    (0..<50).map { index in
      let value = 4_000 / Double(index + 1) + 5
      return TrackedAsset(
        id: "tok-\(index)", address: ChartFixture.evmAddress, chainId: "ethereum",
        chainName: "Ethereum", family: .evm, symbol: "K\(index)", name: "Token \(index)",
        amount: value, priceUsd: 1, valueUsd: value, pricingStatus: .priced, source: .erc20,
        walletLabel: "Main")
    }
  }

  // MARK: Slices

  func testSlicesUnderTheMinimumShareFoldIntoOther() {
    let total = 1000.0
    let slices = [
      slice("A", 600, total: total), slice("B", 300, total: total), slice("C", 80, total: total),
      slice("D", 8, total: total), slice("E", 7, total: total), slice("F", 5, total: total),
    ]
    let folded = AtlasMapModel.folding(slices, minimumShare: 0.01, maximumCount: 24)
    XCTAssertEqual(folded.map(\.key), ["A", "B", "C", AtlasMapSlice.otherKey])
    let other = folded.last
    XCTAssertEqual(other?.isOther, true)
    XCTAssertEqual(other?.label, "Other")
    XCTAssertEqual(other?.value ?? 0, 20, accuracy: 1e-9)
    XCTAssertEqual(other?.share ?? 0, 0.02, accuracy: 1e-9)
    XCTAssertEqual(folded.map(\.value).reduce(0, +), total, accuracy: 1e-9)
  }

  func testASingleSmallSliceIsNotFolded() {
    let total = 1000.0
    let slices = [
      slice("A", 900, total: total), slice("B", 95, total: total), slice("C", 5, total: total),
    ]
    let folded = AtlasMapModel.folding(slices, minimumShare: 0.01, maximumCount: 24)
    XCTAssertEqual(folded.map(\.key), ["A", "B", "C"])
  }

  func testCapacityFoldsTheSmallestIntoOtherAndKeepsTheTotal() {
    let total = (1...30).map(Double.init).reduce(0, +)
    let slices = (1...30).map { slice("S\($0)", Double($0), total: total) }
    let folded = AtlasMapModel.folding(slices, minimumShare: 0, maximumCount: 10)
    XCTAssertEqual(folded.count, 10)
    XCTAssertEqual(folded.last?.isOther, true)
    XCTAssertEqual(folded.map(\.value).reduce(0, +), total, accuracy: 1e-9)
    XCTAssertEqual(folded.first?.key, "S30")
  }

  func testZeroAndNegativeSlicesAreDropped() {
    let slices = [
      slice("A", 10, total: 10), slice("Z", 0, total: 10), slice("N", -3, total: 10),
    ]
    XCTAssertEqual(
      AtlasMapModel.folding(slices, minimumShare: 0.01, maximumCount: 24).map(\.key), ["A"])
  }

  func testCompactFoldsMoreThanFull() {
    let holdings = ChartFixture.latestHoldings
    let full = AtlasMapModel.plan(holdings: holdings, grouping: .asset, compact: false, nesting: .off)
    let compact = AtlasMapModel.plan(
      holdings: holdings, grouping: .asset, compact: true, nesting: .off)
    XCTAssertGreaterThan(full.cellCount, compact.cellCount)
    XCTAssertTrue(compact.slices.contains { $0.isOther })
    XCTAssertEqual(full.total, compact.total, accuracy: 1e-6)
    XCTAssertEqual(
      compact.slices.map(\.value).reduce(0, +), compact.total, accuracy: 1e-6)
  }

  func testUnpricedHoldingsAreCountedNotMapped() {
    let holdings = ChartFixture.holdings(day: 41, includeUnpriced: true)
    let plan = AtlasMapModel.plan(holdings: holdings, grouping: .asset, compact: false, nesting: .off)
    XCTAssertEqual(plan.unpricedCount, 1)
    XCTAssertFalse(plan.slices.contains { $0.key == "MEME" })
  }

  // MARK: Nesting

  func testNestingNeedsTwoToSixBigRegionsInFullAssetMaps() {
    func region(_ key: String, _ share: Double, children: Int) -> AtlasMapRegion {
      AtlasMapRegion(
        key: key, label: key, value: share * 100, share: share,
        children: (0..<children).map {
          AtlasMapSlice(key: "\(key)-\($0)", label: "c", value: 1, share: share / Double(children))
        })
    }
    let four = [region("a", 0.4, children: 2), region("b", 0.3, children: 2),
      region("c", 0.2, children: 2), region("d", 0.1, children: 2)]
    XCTAssertTrue(
      AtlasMapModel.shouldNest(regions: four, grouping: .asset, compact: false, nesting: .automatic))
    XCTAssertFalse(
      AtlasMapModel.shouldNest(regions: four, grouping: .asset, compact: true, nesting: .automatic))
    XCTAssertFalse(
      AtlasMapModel.shouldNest(regions: four, grouping: .network, compact: false, nesting: .automatic))
    XCTAssertFalse(
      AtlasMapModel.shouldNest(regions: four, grouping: .asset, compact: false, nesting: .off))
    XCTAssertFalse(
      AtlasMapModel.shouldNest(
        regions: [region("a", 1, children: 2)], grouping: .asset, compact: false,
        nesting: .automatic))
    let small = four + [region("e", 0.05, children: 1)]
    XCTAssertFalse(
      AtlasMapModel.shouldNest(regions: small, grouping: .asset, compact: false, nesting: .automatic))
    let crowded = [region("a", 0.5, children: 8), region("b", 0.5, children: 7)]
    XCTAssertFalse(
      AtlasMapModel.shouldNest(
        regions: crowded, grouping: .asset, compact: false, nesting: .automatic))
  }

  func testThePlanNestsOnlyWhenLegible() {
    let nested = AtlasMapModel.plan(
      holdings: nestingHoldings, grouping: .asset, compact: false, nesting: .automatic)
    XCTAssertTrue(nested.isNested)
    XCTAssertEqual(nested.regions.count, 4)
    XCTAssertEqual(
      nested.regions.flatMap(\.children).map(\.value).reduce(0, +), nested.total, accuracy: 0.01)
    // The full fixture spans seven networks, two of them small: flat.
    let flat = AtlasMapModel.plan(
      holdings: ChartFixture.latestHoldings, grouping: .asset, compact: false, nesting: .automatic)
    XCTAssertFalse(flat.isNested)
    let off = AtlasMapModel.plan(
      holdings: nestingHoldings, grouping: .asset, compact: false, nesting: .off)
    XCTAssertFalse(off.isNested)
  }

  func testNestedLayoutKeepsCellsInsideTheirRegions() {
    let plan = AtlasMapModel.plan(
      holdings: nestingHoldings, grouping: .asset, compact: false, nesting: .automatic)
    let layout = AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 20)
    XCTAssertEqual(layout.regions.count, 4)
    XCTAssertEqual(layout.cells.count, plan.cellCount)
    for cell in layout.cells {
      guard let region = layout.regions.first(where: { $0.key == cell.regionKey }) else {
        return XCTFail("cell without region \(cell.id)")
      }
      for point in cell.polygon {
        XCTAssertTrue(ConvexPolygon.contains(region.polygon, point), cell.id)
      }
    }
    XCTAssertLessThanOrEqual(layout.maximumError, 0.04)
    // The same coin in two regions is two cells with distinct ids.
    let ids = layout.cells.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count)
  }

  // MARK: Layout

  func testFlatLayoutTilesTheBoundaryWithinTolerance() {
    let plan = AtlasMapModel.plan(
      holdings: ChartFixture.latestHoldings, grouping: .asset, compact: false, nesting: .automatic)
    let layout = AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24)
    XCTAssertEqual(layout.cells.count, plan.slices.count)
    XCTAssertLessThanOrEqual(layout.maximumError, 0.03)
    XCTAssertEqual(
      layout.cells.map(\.area).reduce(0, +), ConvexPolygon.area(layout.boundary), accuracy: 2)
    for cell in layout.cells {
      for point in cell.polygon {
        XCTAssertTrue(ConvexPolygon.contains(layout.boundary, point), cell.id)
      }
    }
  }

  func testLayoutIsDeterministic() {
    let plan = AtlasMapModel.plan(
      holdings: ChartFixture.latestHoldings, grouping: .asset, compact: false, nesting: .off)
    XCTAssertEqual(
      AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24),
      AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24))
  }

  func testEveryGroupingLaysOut() {
    for grouping in PortfolioGrouping.allCases {
      let plan = AtlasMapModel.plan(
        holdings: ChartFixture.latestHoldings, grouping: grouping, compact: false)
      let layout = AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24)
      XCTAssertEqual(layout.cells.count, plan.cellCount, "\(grouping)")
      XCTAssertLessThanOrEqual(layout.maximumError, 0.04, "\(grouping)")
    }
  }

  func testThirtySlicesLayOutQuickly() {
    let holdings = (0..<30).map { index -> TrackedAsset in
      let value = 6_000 / Double(index + 1) + 300
      return TrackedAsset(
        id: "q-\(index)", address: ChartFixture.evmAddress, chainId: "ethereum",
        chainName: "Ethereum", family: .evm, symbol: "Q\(index)", name: "Q\(index)", amount: value,
        priceUsd: 1, valueUsd: value, pricingStatus: .priced, source: .erc20, walletLabel: "Main")
    }
    let plan = AtlasMapModel.plan(holdings: holdings, grouping: .asset, compact: false, nesting: .off)
    XCTAssertEqual(plan.cellCount, 24)
    let start = Date()
    let layout = AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(layout.cells.count, 24)
    // Thread Sanitizer slows a debug build several times over, so the timing
    // check is skipped there; the cell count above still runs.
    if !TestSanitizer.isThreadSanitizerActive {
      #if DEBUG
        XCTAssertLessThan(elapsed, 1.5)
      #else
        XCTAssertLessThan(elapsed, 0.05)
      #endif
    }
    print("atlas map layout, 24 cells: \(Int(elapsed * 1000)) ms")
  }

  // MARK: Hit tests and selection

  func testCellCentresHitTheirCell() {
    let plan = AtlasMapModel.plan(
      holdings: ChartFixture.latestHoldings, grouping: .asset, compact: false, nesting: .off)
    let layout = AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24)
    for cell in layout.cells {
      XCTAssertEqual(AtlasMapModel.hitTest(cell.pole, layout: layout), cell.id)
    }
    XCTAssertNil(AtlasMapModel.hitTest(CGPoint(x: -10, y: -10), layout: layout))
  }

  func testSelectionDependsOnTheGrouping() {
    let cell = AtlasMapCell(
      id: "ETH", key: "ETH", label: "ETH", value: 1, share: 0.5, isOther: false, regionKey: nil,
      regionLabel: nil, polygon: [], pole: .zero, poleRadius: 0, area: 0, targetArea: 0)
    XCTAssertEqual(AtlasMapModel.selection(for: cell, grouping: .asset), .coin("ETH"))
    XCTAssertEqual(
      AtlasMapModel.selection(for: cell, grouping: .network),
      .slice(grouping: .network, key: "ETH"))
    XCTAssertEqual(
      AtlasMapModel.selection(for: cell, grouping: .state), .slice(grouping: .state, key: "ETH"))
    let other = AtlasMapCell(
      id: "o", key: AtlasMapSlice.otherKey, label: "Other", value: 1, share: 0.1, isOther: true,
      regionKey: nil, regionLabel: nil, polygon: [], pole: .zero, poleRadius: 0, area: 0,
      targetArea: 0)
    XCTAssertNil(AtlasMapModel.selection(for: other, grouping: .asset))
  }

  // MARK: Labels

  /// Six points a character, twelve high.
  private func measure(_ text: String, _ index: Int) -> CGSize {
    CGSize(width: CGFloat(text.count) * 6, height: index == 0 ? 14 : 12)
  }

  func testLabelPlannerPicksTheRichestVariantThatFits() {
    let big = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 200, height: 100), cornerRadius: 0)
    let variants = [["BTC", "$27,864 \u{00B7} 48%"], ["BTC", "48%"], ["BTC"]]
    let plan = AtlasMapModel.planLabel(polygon: big, variants: variants, measure: measure)
    XCTAssertEqual(plan?.lines.count, 2)
    XCTAssertEqual(plan?.lines.last, "$27,864 \u{00B7} 48%")
    // A narrow cell drops the value line, a tiny one the share too.
    let narrow = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 50, height: 60), cornerRadius: 0)
    XCTAssertEqual(
      AtlasMapModel.planLabel(polygon: narrow, variants: variants, measure: measure)?.lines,
      ["BTC", "48%"])
    let tiny = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 30, height: 20), cornerRadius: 0)
    XCTAssertEqual(
      AtlasMapModel.planLabel(polygon: tiny, variants: variants, measure: measure)?.lines, ["BTC"])
    let speck = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 12, height: 12), cornerRadius: 0)
    XCTAssertNil(AtlasMapModel.planLabel(polygon: speck, variants: variants, measure: measure))
  }

  func testLabelsKeepInsideTheCellAndClearOfOtherTags() {
    let box = CGRect(x: 0, y: 0, width: 200, height: 100)
    let polygon = ConvexPolygon.roundedRectangle(box, cornerRadius: 0)
    guard let plan = AtlasMapModel.planLabel(
      polygon: polygon, variants: [["BTC", "48%"]], margin: 2, measure: measure)
    else { return XCTFail("no plan") }
    let height = plan.lineSizes.map(\.height).reduce(0, +)
    let width = plan.lineSizes.map(\.width).max() ?? 0
    let rect = CGRect(
      x: plan.center.x - width / 2, y: plan.center.y - height / 2, width: width, height: height)
    XCTAssertTrue(box.contains(rect))
    // A tag over the label's spot makes the planner skip that variant.
    let avoided = AtlasMapModel.planLabel(
      polygon: polygon, variants: [["BTC", "48%"]], margin: 2, avoiding: [rect.insetBy(dx: -50, dy: -50)],
      measure: measure)
    XCTAssertNil(avoided)
  }

  func testCornerLabelSitsInTheTopLeftAndOnlyWhenItFits() {
    let polygon = ConvexPolygon.roundedRectangle(
      CGRect(x: 100, y: 50, width: 200, height: 120), cornerRadius: 30)
    let size = CGSize(width: 60, height: 16)
    let centre = AtlasMapModel.cornerLabelCenter(polygon: polygon, size: size)
    XCTAssertNotNil(centre)
    if let centre {
      XCTAssertLessThan(centre.x, 200)
      XCTAssertLessThan(centre.y, 110)
      for dx in [-1.0, 1.0] {
        for dy in [-1.0, 1.0] {
          XCTAssertTrue(
            ConvexPolygon.contains(
              polygon,
              CGPoint(x: centre.x + dx * size.width / 2, y: centre.y + dy * size.height / 2)))
        }
      }
    }
    XCTAssertNil(
      AtlasMapModel.cornerLabelCenter(polygon: polygon, size: CGSize(width: 400, height: 16)))
  }

  func testWordsReadPlainly() {
    let plan = AtlasMapModel.plan(
      holdings: ChartFixture.latestHoldings, grouping: .asset, compact: false, nesting: .off)
    let summary = AtlasMapModel.summary(plan: plan)
    XCTAssertTrue(summary.hasPrefix("Atlas map of $"), summary)
    XCTAssertTrue(summary.contains("Largest: BTC"), summary)
    let layout = AtlasMapModel.layout(plan: plan, size: full, cornerRadius: 24)
    let eth = layout.cell("ETH")!
    XCTAssertTrue(AtlasMapModel.accessibilityLabel(for: eth).hasPrefix("ETH, $"))
    XCTAssertEqual(AtlasMapModel.tooltipLines(for: eth).count, 2)
  }

  // MARK: Rendering

  func testEmptyInputRendersAMessage() throws {
    let tokens = AtlasThemeTokens(theme: .heatmap, variant: .dark)
    _ = try ChartRenderTests.renderImage(
      AnyView(AtlasMapChartView(input: PortfolioChartInput(holdings: []))), tokens: tokens,
      colorScheme: .dark, size: full)
  }

  func testEveryThemeDrawsNestedFlatAndFoldedMaps() throws {
    let directory = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_DIR"]
    let writes = ProcessInfo.processInfo.environment["ATLAS_WRITE_SCREENSHOTS"] == "1"
    let cases: [(String, [TrackedAsset], PortfolioGrouping)] = [
      ("nested", nestingHoldings, .asset),
      ("folded", manyTokens(), .asset),
      ("network", ChartFixture.latestHoldings, .network),
      ("state", ChartFixture.latestHoldings, .state),
    ]
    for (name, holdings, grouping) in cases {
      for density in [PortfolioChartDensity.full, .compact] {
        for theme in AtlasThemeID.allCases {
          let variant: AtlasAppearanceVariant = theme == .acid ? .dark : .light
          let tokens = AtlasThemeTokens(theme: theme, variant: variant)
          let size = density == .full ? CGSize(width: 640, height: 400) : CGSize(width: 320, height: 200)
          let input = PortfolioChartInput(holdings: holdings, grouping: grouping, density: density)
          let image = try ChartRenderTests.renderImage(
            AnyView(AtlasMapChartView(input: input)), tokens: tokens,
            colorScheme: variant.isDark ? .dark : .light, size: size)
          XCTAssertGreaterThan(ChartRenderTests.distinctColors(in: image), 8, "\(name) \(theme)")
          if writes, let directory {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file =
              "atlas-map-\(name)-\(theme.rawValue)-\(density == .full ? "full" : "compact").png"
            try ChartRenderTests.pngData(image).write(to: folder.appendingPathComponent(file))
          }
        }
      }
    }
  }
}
