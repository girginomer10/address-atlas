import AddressAtlasCore
import CoreGraphics
import Foundation
import XCTest

@testable import AddressAtlasMac

final class SankeyLayoutEngineTests: XCTestCase {
  private func config(height: CGFloat = 360, minimum: CGFloat = 16, padding: CGFloat = 6)
    -> SankeyLayoutConfig
  {
    SankeyLayoutConfig(
      width: 640, height: height, nodeWidths: [10, 48, 10], leftInset: 110, rightInset: 90,
      nodePadding: padding, minimumNodeHeight: minimum)
  }

  private func fixtureGraph() -> SankeyGraph {
    SankeyGraph(flow: PortfolioAnalytics.flowGraph(ChartFixture.latestHoldings))
  }

  /// Many coins held through a few sources, to force collapsing.
  private func wideGraph(coins: Int) -> SankeyGraph {
    var nodes: [SankeyGraph.Node] = []
    var edges: [SankeyGraph.Edge] = []
    let sources = ["a", "b", "c"]
    for (index, source) in sources.enumerated() {
      nodes.append(
        SankeyGraph.Node(
          id: "source:\(source)", column: 0, value: 0, label: source.uppercased(), key: source,
          isOther: false))
      _ = index
    }
    var sourceTotals: [String: Double] = [:]
    var stateTotals: [String: Double] = [:]
    for coin in 0..<coins {
      let value = 2_000 / Double(coin + 1) + 10
      let source = sources[coin % 3]
      let state = coin % 4 == 0 ? "staked" : "liquid"
      nodes.append(
        SankeyGraph.Node(
          id: "coin:C\(coin)", column: 1, value: value, label: "C\(coin)", key: "C\(coin)",
          isOther: false))
      edges.append(SankeyGraph.Edge(from: "source:\(source)", to: "coin:C\(coin)", value: value))
      edges.append(SankeyGraph.Edge(from: "coin:C\(coin)", to: "state:\(state)", value: value))
      sourceTotals[source, default: 0] += value
      stateTotals[state, default: 0] += value
    }
    nodes = nodes.map { node in
      guard node.column == 0 else { return node }
      return SankeyGraph.Node(
        id: node.id, column: 0, value: sourceTotals[node.key] ?? 0, label: node.label,
        key: node.key, isOther: false)
    }
    for (state, total) in stateTotals.sorted(by: { $0.key < $1.key }) {
      nodes.append(
        SankeyGraph.Node(
          id: "state:\(state)", column: 2, value: total, label: state, key: state, isOther: false))
    }
    return SankeyGraph(nodes: nodes, edges: edges)
  }

  // MARK: Properties

  func testNodesNeverOverlapAndStayInsideTheHeight() {
    for height in [360.0, 200.0, 120.0] {
      let layout = SankeyLayoutEngine.make(
        graph: fixtureGraph().collapsingSmallNodes(maximumPerColumn: 14),
        config: config(height: CGFloat(height)))
      XCTAssertFalse(layout.nodes.isEmpty)
      for column in 0...2 {
        let nodes = layout.nodes.filter { $0.column == column }.sorted { $0.rect.minY < $1.rect.minY }
        for node in nodes {
          XCTAssertGreaterThanOrEqual(node.rect.minY, -0.001, node.id)
          XCTAssertLessThanOrEqual(node.rect.maxY, CGFloat(height) + 0.001, node.id)
        }
        for (upper, lower) in zip(nodes, nodes.dropFirst()) {
          XCTAssertLessThanOrEqual(upper.rect.maxY, lower.rect.minY + 0.001, "\(upper.id) / \(lower.id)")
        }
      }
    }
  }

  func testEveryNodeIsAtLeastTheMinimumHeight() {
    let layout = SankeyLayoutEngine.make(graph: fixtureGraph(), config: config(minimum: 16))
    for node in layout.nodes {
      XCTAssertGreaterThanOrEqual(node.rect.height, 16 - 0.001, node.id)
    }
  }

  func testLinkWidthsConserveValueAtEveryNode() {
    let graph = fixtureGraph()
    let layout = SankeyLayoutEngine.make(graph: graph, config: config())
    XCTAssertGreaterThan(layout.scale, 0)
    for node in layout.nodes {
      let outgoing = layout.links.filter { $0.from == node.id }.map(\.thickness).reduce(0, +)
      let incoming = layout.links.filter { $0.to == node.id }.map(\.thickness).reduce(0, +)
      let expected = CGFloat(node.value) * layout.scale
      if node.column < 2 { XCTAssertEqual(outgoing, expected, accuracy: 0.01, "out \(node.id)") }
      if node.column > 0 { XCTAssertEqual(incoming, expected, accuracy: 0.01, "in \(node.id)") }
    }
    for link in layout.links {
      XCTAssertEqual(link.thickness, CGFloat(link.value) * layout.scale, accuracy: 0.0001)
    }
  }

  func testLinksStayInsideTheirNodes() {
    let layout = SankeyLayoutEngine.make(graph: fixtureGraph(), config: config())
    for link in layout.links {
      guard let from = layout.node(link.from), let to = layout.node(link.to) else {
        return XCTFail("link without node")
      }
      XCTAssertGreaterThanOrEqual(link.y0, from.rect.minY - 0.001)
      XCTAssertLessThanOrEqual(link.y0 + link.thickness, from.rect.maxY + 0.001)
      XCTAssertGreaterThanOrEqual(link.y1, to.rect.minY - 0.001)
      XCTAssertLessThanOrEqual(link.y1 + link.thickness, to.rect.maxY + 0.001)
      XCTAssertEqual(link.x0, from.rect.maxX, accuracy: 0.001)
      XCTAssertEqual(link.x1, to.rect.minX, accuracy: 0.001)
    }
  }

  func testLinksSharingANodeDoNotOverlapEachOther() {
    let layout = SankeyLayoutEngine.make(graph: fixtureGraph(), config: config())
    for node in layout.nodes {
      let outgoing = layout.links.filter { $0.from == node.id }.sorted { $0.y0 < $1.y0 }
      for (upper, lower) in zip(outgoing, outgoing.dropFirst()) {
        XCTAssertLessThanOrEqual(upper.y0 + upper.thickness, lower.y0 + 0.001)
      }
      let incoming = layout.links.filter { $0.to == node.id }.sorted { $0.y1 < $1.y1 }
      for (upper, lower) in zip(incoming, incoming.dropFirst()) {
        XCTAssertLessThanOrEqual(upper.y1 + upper.thickness, lower.y1 + 0.001)
      }
    }
  }

  func testOrderingNeverCrossesMoreThanValueOrder() {
    let graph = wideGraph(coins: 9)
    var baseline: [Int: [String]] = [:]
    for column in graph.columns {
      baseline[column] = graph.nodes(inColumn: column).sorted {
        if $0.value != $1.value { return $0.value > $1.value }
        return $0.id < $1.id
      }.map(\.id)
    }
    let valueOrderCrossings = SankeyLayoutEngine.crossingCount(graph: graph, order: baseline)
    let layout = SankeyLayoutEngine.make(graph: graph, config: config())
    XCTAssertLessThanOrEqual(layout.crossings, valueOrderCrossings)
    // The three-source layout is not planar, but sweeps should improve on value
    // order here.
    XCTAssertLessThan(layout.crossings, valueOrderCrossings)
  }

  func testCoinsOfOneSourceStayAdjacentWhenThatCostsNothing() {
    // Source A feeds C0 and C1, source B feeds C2 and C3. Value order would
    // interleave them (C0 > C1 > C2 > C3 is fine), but with A feeding C0 and C2
    // a value-ordered middle column crosses, and sweeps should untangle it.
    let nodes = [
      SankeyGraph.Node(id: "source:A", column: 0, value: 70, label: "A", key: "A", isOther: false),
      SankeyGraph.Node(id: "source:B", column: 0, value: 30, label: "B", key: "B", isOther: false),
      SankeyGraph.Node(id: "coin:C0", column: 1, value: 40, label: "C0", key: "C0", isOther: false),
      SankeyGraph.Node(id: "coin:C1", column: 1, value: 30, label: "C1", key: "C1", isOther: false),
      SankeyGraph.Node(id: "coin:C2", column: 1, value: 20, label: "C2", key: "C2", isOther: false),
      SankeyGraph.Node(id: "coin:C3", column: 1, value: 10, label: "C3", key: "C3", isOther: false),
    ]
    let edges = [
      SankeyGraph.Edge(from: "source:A", to: "coin:C0", value: 40),
      SankeyGraph.Edge(from: "source:A", to: "coin:C2", value: 20),
      SankeyGraph.Edge(from: "source:A", to: "coin:C3", value: 10),
      SankeyGraph.Edge(from: "source:B", to: "coin:C1", value: 30),
    ]
    let layout = SankeyLayoutEngine.make(
      graph: SankeyGraph(nodes: nodes, edges: edges), config: config())
    XCTAssertEqual(layout.crossings, 0)
    let order = layout.nodes.filter { $0.column == 1 }.sorted { $0.rect.minY < $1.rect.minY }
      .map(\.id)
    XCTAssertEqual(order.last, "coin:C1")
  }

  func testLayoutIsDeterministicAndIgnoresInputOrder() {
    let graph = fixtureGraph()
    let first = SankeyLayoutEngine.make(graph: graph, config: config())
    let second = SankeyLayoutEngine.make(graph: graph, config: config())
    XCTAssertEqual(first, second)
    let shuffled = SankeyGraph(nodes: graph.nodes.reversed(), edges: graph.edges.reversed())
    let third = SankeyLayoutEngine.make(graph: shuffled, config: config())
    XCTAssertEqual(first.nodes.map(\.id), third.nodes.map(\.id))
    XCTAssertEqual(first.crossings, third.crossings)
  }

  // MARK: Collapsing

  func testCollapsingKeepsColumnTotalsAndCapsTheNodeCount() {
    let graph = wideGraph(coins: 30)
    let configuration = config(height: 200, minimum: 14, padding: 4)
    let capacity = configuration.nodeCapacity
    XCTAssertLessThan(capacity, 30)
    let collapsed = graph.collapsingSmallNodes(maximumPerColumn: capacity) { column in
      column == 1 ? "Other coins" : "Other"
    }
    XCTAssertLessThanOrEqual(collapsed.nodes(inColumn: 1).count, capacity)
    XCTAssertEqual(
      collapsed.nodes(inColumn: 1).map(\.value).reduce(0, +),
      graph.nodes(inColumn: 1).map(\.value).reduce(0, +), accuracy: 0.0001)
    let other = collapsed.nodes.first { $0.id == SankeyGraph.otherID(column: 1) }
    XCTAssertEqual(other?.label, "Other coins")
    XCTAssertEqual(other?.isOther, true)
    // Edges still add up to the same totals.
    XCTAssertEqual(
      collapsed.edges.map(\.value).reduce(0, +), graph.edges.map(\.value).reduce(0, +),
      accuracy: 0.0001)

    let layout = SankeyLayoutEngine.make(graph: collapsed, config: configuration)
    for column in 0...2 {
      let nodes = layout.nodes.filter { $0.column == column }.sorted { $0.rect.minY < $1.rect.minY }
      for (upper, lower) in zip(nodes, nodes.dropFirst()) {
        XCTAssertLessThanOrEqual(upper.rect.maxY, lower.rect.minY + 0.001)
      }
      for node in nodes { XCTAssertLessThanOrEqual(node.rect.maxY, 200.001) }
    }
  }

  func testCollapsingLeavesSmallColumnsAlone() {
    let graph = fixtureGraph()
    XCTAssertEqual(graph.collapsingSmallNodes(maximumPerColumn: 50), graph)
  }

  func testNodeCapacityFollowsHeightAndMinimum() {
    XCTAssertEqual(config(height: 200, minimum: 14, padding: 4).nodeCapacity, 11)
    XCTAssertEqual(config(height: 360, minimum: 16, padding: 6).nodeCapacity, 16)
  }

  // MARK: Edge cases

  func testEmptyAndSingleNodeGraphs() {
    let empty = SankeyLayoutEngine.make(graph: SankeyGraph(nodes: [], edges: []), config: config())
    XCTAssertTrue(empty.nodes.isEmpty)
    XCTAssertEqual(empty.scale, 0)
    let single = SankeyLayoutEngine.make(
      graph: SankeyGraph(
        nodes: [
          SankeyGraph.Node(id: "coin:BTC", column: 1, value: 5, label: "BTC", key: "BTC", isOther: false)
        ], edges: []),
      config: config())
    XCTAssertEqual(single.nodes.count, 1)
    XCTAssertTrue(single.links.isEmpty)
  }

  func testGraphFromAnalyticsMatchesTheFlowTotals() {
    let flow = PortfolioAnalytics.flowGraph(ChartFixture.latestHoldings)
    let graph = SankeyGraph(flow: flow)
    for column in 0...2 {
      XCTAssertEqual(
        graph.nodes(inColumn: column).map(\.value).reduce(0, +), flow.totalValueUsd,
        accuracy: 0.01, "column \(column)")
    }
  }
}
