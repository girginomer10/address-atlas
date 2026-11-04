import AddressAtlasCore
import CoreGraphics
import Foundation

// Pure model behind `FlowChartView`: sizing, folding of tiny nodes, hit tests,
// selection keys, and the plain-language strings. No SwiftUI, so it can be
// tested without rendering.

/// What the pointer is over in the flow chart.
enum FlowChartTarget: Hashable {
  case node(String)
  case link(String)
}

/// Inputs that change the layout. Hover state is deliberately not part of it.
struct FlowChartKey: Equatable {
  var width: CGFloat
  var height: CGFloat
  var compact: Bool
}

struct FlowChartLayout {
  let graph: SankeyGraph
  let result: SankeyLayoutResult
  let config: SankeyLayoutConfig
  /// Priced value of the whole flow.
  let total: Double
  private let nodeByID: [String: SankeyGraph.Node]
  private let boxByID: [String: SankeyNodeBox]

  init(graph: SankeyGraph, result: SankeyLayoutResult, config: SankeyLayoutConfig, total: Double) {
    self.graph = graph
    self.result = result
    self.config = config
    self.total = total
    nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    boxByID = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
  }

  func node(_ id: String) -> SankeyGraph.Node? { nodeByID[id] }
  func box(_ id: String) -> SankeyNodeBox? { boxByID[id] }
  func share(_ value: Double) -> Double { total > 0 ? min(max(value / total, 0), 1) : 0 }
}

enum FlowChartModel {
  // MARK: Sizing

  /// Layout settings for a canvas of `size`. Labels are drawn outside the
  /// outer columns, in insets that are fractions of the width, so the layout
  /// never depends on measured text.
  static func config(size: CGSize, compact: Bool) -> SankeyLayoutConfig {
    let width = max(size.width, 1)
    let left = min(max(width * (compact ? 0.24 : 0.2), 56), 150)
    let right = min(max(width * (compact ? 0.26 : 0.17), 50), 120)
    return SankeyLayoutConfig(
      width: width,
      height: max(size.height, 1),
      nodeWidths: [compact ? 6 : 8, compact ? 38 : 54, compact ? 6 : 8],
      leftInset: left,
      rightInset: right,
      nodePadding: compact ? 3 : 6,
      minimumNodeHeight: compact ? 14 : 20)
  }

  static func key(size: CGSize, compact: Bool) -> FlowChartKey {
    FlowChartKey(width: size.width.rounded(), height: size.height.rounded(), compact: compact)
  }

  /// Smallest share a node may have before it is folded into "Other" (when at
  /// least two nodes of its column are that small).
  static func tinyShare(compact: Bool) -> Double { compact ? 0.03 : 0 }

  static func otherLabel(column: Int) -> String {
    switch column {
    case 0: "Other sources"
    case 1: "Other coins"
    default: "Other"
    }
  }

  /// Folds a column's smallest nodes into one "Other" node when the column holds
  /// more nodes than fit at the minimum label height, or holds two or more
  /// nodes under `tinyShare` of the column. A single tiny node is left alone,
  /// because "Other" holding one node would say less than the node itself.
  static func foldedGraph(
    _ graph: SankeyGraph, capacity: Int, tinyShare: Double
  ) -> SankeyGraph {
    graph.collapsing(
      keepCount: { _, members in
        let count = members.count
        let columnTotal = members.map(\.value).reduce(0, +)
        let tiny =
          columnTotal > 0
          ? members.filter { $0.value < tinyShare * columnTotal }.count : 0
        let capacityFold = count > capacity ? count - capacity + 1 : 0
        let fold = max(capacityFold, tiny >= 2 ? tiny : 0)
        guard fold >= 2 else { return count }
        return count - fold + 1
      },
      otherLabel: otherLabel(column:))
  }

  static func layout(flow: FlowGraph, size: CGSize, compact: Bool) -> FlowChartLayout {
    let config = config(size: size, compact: compact)
    let graph = foldedGraph(
      SankeyGraph(flow: flow), capacity: config.nodeCapacity, tinyShare: tinyShare(compact: compact))
    let result = SankeyLayoutEngine.make(graph: graph, config: config)
    return FlowChartLayout(graph: graph, result: result, config: config, total: flow.totalValueUsd)
  }

  // MARK: Selection

  /// What a click on `node` selects; nil for the combined "Other" nodes.
  static func selection(for node: SankeyGraph.Node) -> PortfolioChartSelection? {
    guard !node.isOther else { return nil }
    switch node.column {
    case 0: return .slice(grouping: .source, key: node.key)
    case 1: return .coin(node.key)
    default: return .slice(grouping: .state, key: node.key)
    }
  }

  /// A link belongs to one coin: its target in the source column's links, its
  /// origin in the state column's.
  static func selection(for link: SankeyLinkBox, in layout: FlowChartLayout)
    -> PortfolioChartSelection?
  {
    guard let target = layout.node(link.to), let origin = layout.node(link.from) else { return nil }
    if target.column == 1 { return selection(for: target) }
    if origin.column == 1 { return selection(for: origin) }
    return nil
  }

  static func selection(for target: FlowChartTarget, in layout: FlowChartLayout)
    -> PortfolioChartSelection?
  {
    switch target {
    case .node(let id):
      return layout.node(id).flatMap { selection(for: $0) }
    case .link(let id):
      return layout.result.links.first { $0.id == id }.flatMap { selection(for: $0, in: layout) }
    }
  }

  // MARK: Hit testing

  /// The area that counts as a node: the bar itself, plus the label beside an
  /// outer column.
  static func hitRect(for box: SankeyNodeBox, layout: FlowChartLayout) -> CGRect {
    var rect = box.rect.insetBy(dx: -2, dy: -layout.config.nodePadding / 2)
    switch box.column {
    case 0: rect = CGRect(x: 0, y: rect.minY, width: rect.maxX, height: rect.height)
    case 2:
      rect = CGRect(
        x: rect.minX, y: rect.minY, width: max(rect.width, layout.config.width - rect.minX),
        height: rect.height)
    default: break
    }
    return rect
  }

  /// Top edge of a link ribbon at horizontal position `x`, following the cubic
  /// curve the ribbon is drawn with; nil outside the ribbon.
  static func linkTop(_ link: SankeyLinkBox, atX x: CGFloat) -> CGFloat? {
    guard link.x1 > link.x0, x >= link.x0, x <= link.x1 else { return nil }
    let mid = (link.x0 + link.x1) / 2
    func curveX(_ u: CGFloat) -> CGFloat {
      let v = 1 - u
      return link.x0 * v * v * v + 3 * mid * v * v * u + 3 * mid * v * u * u + link.x1 * u * u * u
    }
    var low: CGFloat = 0
    var high: CGFloat = 1
    for _ in 0..<32 {
      let centre = (low + high) / 2
      if curveX(centre) < x { low = centre } else { high = centre }
    }
    let u = (low + high) / 2
    let v = 1 - u
    return link.y0 * (v * v * v + 3 * v * v * u) + link.y1 * (3 * v * u * u + u * u * u)
  }

  static func hitTest(_ point: CGPoint, layout: FlowChartLayout) -> FlowChartTarget? {
    for box in layout.result.nodes where hitRect(for: box, layout: layout).contains(point) {
      return .node(box.id)
    }
    return linksCovering(point, layout: layout).first.map { .link($0.id) }
  }

  /// Links whose ribbon covers `point` (thin ribbons count as 3 points thick so
  /// they can be hovered), thinnest first: where ribbons cross, the pointer
  /// picks the more specific one.
  static func linksCovering(_ point: CGPoint, layout: FlowChartLayout) -> [SankeyLinkBox] {
    layout.result.links.filter { link in
      guard let top = linkTop(link, atX: point.x) else { return false }
      let thickness = max(link.thickness, 3)
      return point.y >= top - 1 && point.y <= top + thickness + 1
    }.sorted { lhs, rhs in
      if lhs.thickness != rhs.thickness { return lhs.thickness < rhs.thickness }
      return lhs.id < rhs.id
    }
  }

  /// Links lit up when `target` is hovered: a node's own links, or the link and
  /// the other links of the same coin.
  static func highlightedLinks(for target: FlowChartTarget, in layout: FlowChartLayout)
    -> Set<String>
  {
    switch target {
    case .node(let id):
      return Set(layout.result.links.filter { $0.from == id || $0.to == id }.map(\.id))
    case .link(let id):
      return [id]
    }
  }

  static func highlightedNodes(for target: FlowChartTarget, in layout: FlowChartLayout)
    -> Set<String>
  {
    switch target {
    case .node(let id):
      var ids: Set<String> = [id]
      for link in layout.result.links where link.from == id || link.to == id {
        ids.insert(link.from)
        ids.insert(link.to)
      }
      return ids
    case .link(let id):
      guard let link = layout.result.links.first(where: { $0.id == id }) else { return [] }
      return [link.from, link.to]
    }
  }

  // MARK: Words

  static func columnName(_ column: Int) -> String {
    switch column {
    case 0: "wallet or exchange"
    case 1: "coin"
    default: "state"
    }
  }

  static func valueLine(value: Double, share: Double) -> String {
    "\(HistoryChartFormat.usd(value)) \u{00B7} \(HistoryChartFormat.percent(share))"
  }

  static func tooltipLines(for target: FlowChartTarget, in layout: FlowChartLayout) -> [String] {
    switch target {
    case .node(let id):
      guard let node = layout.node(id) else { return [] }
      return [node.label, valueLine(value: node.value, share: layout.share(node.value))]
    case .link(let id):
      guard let link = layout.result.links.first(where: { $0.id == id }),
        let from = layout.node(link.from), let to = layout.node(link.to)
      else { return [] }
      return [
        "\(from.label) \u{2192} \(to.label)",
        valueLine(value: link.value, share: layout.share(link.value)),
      ]
    }
  }

  /// Where a tooltip for `target` points.
  static func anchor(for target: FlowChartTarget, in layout: FlowChartLayout) -> CGPoint? {
    switch target {
    case .node(let id):
      return layout.box(id).map { CGPoint(x: $0.rect.maxX, y: $0.rect.midY) }
    case .link(let id):
      guard let link = layout.result.links.first(where: { $0.id == id }) else { return nil }
      let x = (link.x0 + link.x1) / 2
      let top = linkTop(link, atX: x) ?? link.y0
      return CGPoint(x: x, y: top + link.thickness / 2)
    }
  }

  static func accessibilityLabel(for node: SankeyGraph.Node, in layout: FlowChartLayout) -> String {
    let name = node.isOther ? node.label : node.label
    let kind = node.isOther ? "" : ", \(columnName(node.column))"
    return
      "\(name)\(kind), \(HistoryChartFormat.usd(node.value)), \(HistoryChartFormat.percent(layout.share(node.value))) of the portfolio"
  }

  /// One sentence for the whole chart.
  static func summary(flow: FlowGraph) -> String {
    let sources = flow.nodes.filter { $0.column == .source }.count
    let coins = flow.nodes.filter { $0.column == .coin }
    let states = flow.nodes.filter { $0.column == .state }.count
    var text =
      "Flow of \(HistoryChartFormat.usd(flow.totalValueUsd)) from "
      + "\(HistoryChartFormat.count(sources, "wallet or exchange", plural: "wallets or exchanges")) "
      + "through \(HistoryChartFormat.count(coins.count, "coin")) "
      + "into \(HistoryChartFormat.count(states, "state"))."
    if let largest = coins.first, flow.totalValueUsd > 0 {
      text +=
        " Largest coin: \(largest.label), \(HistoryChartFormat.percent(largest.valueUsd / flow.totalValueUsd))."
    }
    return text
  }

  static func unpricedNote(count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
      ? "1 holding has no price and is not shown."
      : "\(count) holdings have no price and are not shown."
  }
}
