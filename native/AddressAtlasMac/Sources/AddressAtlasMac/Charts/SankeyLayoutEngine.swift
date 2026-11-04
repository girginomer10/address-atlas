import AddressAtlasCore
import CoreGraphics
import Foundation

// Pure layout for the Flow (Sankey) chart: no SwiftUI, no theme, no clock.
// Equal inputs give equal outputs.
//
// The layout works in three steps.
//   1. `SankeyGraph.collapsingSmallNodes` folds the smallest nodes of a column
//      into one "Other" node, so every node that remains can carry a label.
//   2. `SankeyLayoutEngine.make` orders the nodes of every column to reduce
//      link crossings (value order first, then barycenter sweeps, keeping
//      whichever order crosses least), sizes them with one value-to-height
//      scale shared by all columns, and stacks the links inside each node in
//      the order of their other end, so links that share a node never cross.
//   3. The result holds node boxes and link ribbons in points.
//
// Heights. A node is as tall as its value times the shared scale, but never
// shorter than `minimumNodeHeight`. Link thickness is always exactly
// `value * scale`, so links conserve value and a node that was raised to the
// minimum height is simply taller than the links it carries.

// MARK: - Graph

struct SankeyGraph: Equatable {
  struct Node: Equatable, Identifiable {
    let id: String
    let column: Int
    let value: Double
    let label: String
    /// The group key without a column prefix, for colour and selection.
    let key: String
    /// True for the combined remainder node; it is not selectable.
    let isOther: Bool
  }

  struct Edge: Equatable {
    let from: String
    let to: String
    let value: Double
  }

  var nodes: [Node]
  var edges: [Edge]

  init(nodes: [Node], edges: [Edge]) {
    self.nodes = nodes
    self.edges = edges
  }

  /// The analytics flow graph (source, coin, state) as layout input.
  init(flow: FlowGraph) {
    nodes = flow.nodes.filter { $0.valueUsd > 0 }.map {
      Node(
        id: $0.id, column: $0.column.rawValue, value: $0.valueUsd, label: $0.label, key: $0.key,
        isOther: false)
    }
    let ids = Set(nodes.map(\.id))
    edges = flow.edges.filter { $0.valueUsd > 0 && ids.contains($0.from) && ids.contains($0.to) }
      .map { Edge(from: $0.from, to: $0.to, value: $0.valueUsd) }
  }

  var columns: [Int] { Array(Set(nodes.map(\.column))).sorted() }

  func nodes(inColumn column: Int) -> [Node] {
    nodes.filter { $0.column == column }
  }

  static func otherID(column: Int) -> String { "other:\(column)" }

  /// Folds the smallest nodes of any column holding more than `maximumPerColumn`
  /// nodes into one "Other" node (labelled by `otherLabel`), re-pointing and
  /// merging their edges. Nothing is dropped: column totals are unchanged.
  func collapsingSmallNodes(
    maximumPerColumn: Int,
    otherLabel: (Int) -> String = { _ in "Other" }
  ) -> SankeyGraph {
    guard maximumPerColumn >= 2 else { return self }
    var replacement: [String: String] = [:]
    var newNodes: [Node] = []
    for column in columns {
      let members = nodes(inColumn: column)
      guard members.count > maximumPerColumn else {
        newNodes += members
        continue
      }
      let ordered = members.sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        if lhs.label != rhs.label { return lhs.label < rhs.label }
        return lhs.id < rhs.id
      }
      let kept = ordered.prefix(maximumPerColumn - 1)
      let folded = ordered.dropFirst(maximumPerColumn - 1)
      newNodes += kept
      let otherID = Self.otherID(column: column)
      for node in folded { replacement[node.id] = otherID }
      let foldedValue = folded.map(\.value).sorted().reduce(0, +)
      newNodes.append(
        Node(
          id: otherID, column: column, value: foldedValue, label: otherLabel(column),
          key: otherID, isOther: true))
    }
    var merged: [String: Edge] = [:]
    var order: [String] = []
    for edge in edges {
      let from = replacement[edge.from] ?? edge.from
      let to = replacement[edge.to] ?? edge.to
      let id = "\(from)>\(to)"
      if let existing = merged[id] {
        merged[id] = Edge(from: from, to: to, value: existing.value + edge.value)
      } else {
        merged[id] = Edge(from: from, to: to, value: edge.value)
        order.append(id)
      }
    }
    return SankeyGraph(nodes: newNodes, edges: order.compactMap { merged[$0] })
  }
}

// MARK: - Layout

struct SankeyLayoutConfig: Equatable {
  var width: CGFloat
  var height: CGFloat
  /// Node width by column index.
  var nodeWidths: [CGFloat]
  /// Space kept free on the left and right for labels outside the nodes.
  var leftInset: CGFloat
  var rightInset: CGFloat
  /// Vertical gap between nodes of one column.
  var nodePadding: CGFloat
  /// Shortest a node may be drawn; sized to carry one line of label text.
  var minimumNodeHeight: CGFloat

  /// The most nodes a column can hold at this height and minimum node height.
  var nodeCapacity: Int {
    guard height > 0, minimumNodeHeight > 0 else { return 1 }
    return max(1, Int(floor((height + nodePadding) / (minimumNodeHeight + nodePadding))))
  }
}

struct SankeyNodeBox: Equatable, Identifiable {
  let id: String
  let column: Int
  let value: Double
  let rect: CGRect
}

struct SankeyLinkBox: Equatable, Identifiable {
  var id: String { "\(from)>\(to)" }
  let from: String
  let to: String
  let value: Double
  /// `value * scale`, in points.
  let thickness: CGFloat
  /// Right edge of the source node and left edge of the target node.
  let x0: CGFloat
  let x1: CGFloat
  /// Top of the ribbon at each end.
  let y0: CGFloat
  let y1: CGFloat
}

struct SankeyLayoutResult: Equatable {
  let nodes: [SankeyNodeBox]
  let links: [SankeyLinkBox]
  /// Points per dollar.
  let scale: CGFloat
  /// Number of link pairs that cross between neighbouring columns.
  let crossings: Int

  func node(_ id: String) -> SankeyNodeBox? { nodes.first { $0.id == id } }
}

enum SankeyLayoutEngine {
  static let sweepCount = 8

  static func make(graph: SankeyGraph, config: SankeyLayoutConfig) -> SankeyLayoutResult {
    let columns = graph.columns
    guard !graph.nodes.isEmpty, config.width > 0, config.height > 0, !columns.isEmpty else {
      return SankeyLayoutResult(nodes: [], links: [], scale: 0, crossings: 0)
    }

    // Order: value order is the baseline; barycenter sweeps may improve on it.
    var baseline: [Int: [String]] = [:]
    for column in columns {
      baseline[column] = graph.nodes(inColumn: column).sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        if lhs.label != rhs.label { return lhs.label < rhs.label }
        return lhs.id < rhs.id
      }.map(\.id)
    }
    var best = baseline
    var bestCrossings = crossingCount(graph: graph, order: baseline)
    var working = baseline
    if bestCrossings > 0 {
      for sweep in 0..<sweepCount {
        let forward = sweep % 2 == 0
        let sequence = forward ? columns : columns.reversed()
        for (index, column) in sequence.enumerated() where index > 0 {
          let neighbour = sequence[index - 1]
          working[column] = reordered(
            graph: graph, column: column, neighbour: neighbour, order: working)
        }
        let crossings = crossingCount(graph: graph, order: working)
        if crossings < bestCrossings {
          bestCrossings = crossings
          best = working
        }
        if bestCrossings == 0 { break }
      }
    }

    // Heights.
    let capacityMinimum = minimumHeight(graph: graph, config: config, columns: columns)
    let scale = scale(graph: graph, config: config, minimum: capacityMinimum, columns: columns)
    var heights: [String: CGFloat] = [:]
    for node in graph.nodes {
      heights[node.id] = max(CGFloat(node.value) * scale, capacityMinimum)
    }

    // Positions.
    let columnCount = max(columns.max() ?? 0, 1)
    func nodeWidth(_ column: Int) -> CGFloat {
      column < config.nodeWidths.count ? config.nodeWidths[column] : (config.nodeWidths.last ?? 10)
    }
    let usable = max(0, config.width - config.leftInset - config.rightInset)
    var boxes: [String: SankeyNodeBox] = [:]
    for column in columns {
      let ids = best[column] ?? []
      let stack =
        ids.map { heights[$0] ?? 0 }.reduce(0, +) + config.nodePadding * CGFloat(max(0, ids.count - 1))
      var y = max(0, (config.height - stack) / 2)
      let width = nodeWidth(column)
      let x =
        config.leftInset + (columnCount == 0 ? 0 : CGFloat(column) / CGFloat(columnCount))
        * max(0, usable - width)
      for id in ids {
        guard let node = graph.nodes.first(where: { $0.id == id }) else { continue }
        let height = heights[id] ?? 0
        boxes[id] = SankeyNodeBox(
          id: id, column: column, value: node.value,
          rect: CGRect(x: x, y: y, width: width, height: height))
        y += height + config.nodePadding
      }
    }

    // Links: stacked inside each node in the order of the other end.
    let nodeIndex: [String: Int] = {
      var index: [String: Int] = [:]
      for (_, ids) in best { for (position, id) in ids.enumerated() { index[id] = position } }
      return index
    }()
    var outgoing: [String: [SankeyGraph.Edge]] = [:]
    var incoming: [String: [SankeyGraph.Edge]] = [:]
    for edge in graph.edges where boxes[edge.from] != nil && boxes[edge.to] != nil {
      outgoing[edge.from, default: []].append(edge)
      incoming[edge.to, default: []].append(edge)
    }
    var sourceTop: [String: CGFloat] = [:]
    var targetTop: [String: CGFloat] = [:]
    for (id, edges) in outgoing {
      guard let box = boxes[id] else { continue }
      let ordered = edges.sorted { lhs, rhs in
        let left = nodeIndex[lhs.to] ?? 0
        let right = nodeIndex[rhs.to] ?? 0
        if left != right { return left < right }
        return lhs.to < rhs.to
      }
      let total = ordered.map { CGFloat($0.value) * scale }.reduce(0, +)
      var y = box.rect.minY + max(0, (box.rect.height - total) / 2)
      for edge in ordered {
        sourceTop["\(edge.from)>\(edge.to)"] = y
        y += CGFloat(edge.value) * scale
      }
    }
    for (id, edges) in incoming {
      guard let box = boxes[id] else { continue }
      let ordered = edges.sorted { lhs, rhs in
        let left = nodeIndex[lhs.from] ?? 0
        let right = nodeIndex[rhs.from] ?? 0
        if left != right { return left < right }
        return lhs.from < rhs.from
      }
      let total = ordered.map { CGFloat($0.value) * scale }.reduce(0, +)
      var y = box.rect.minY + max(0, (box.rect.height - total) / 2)
      for edge in ordered {
        targetTop["\(edge.from)>\(edge.to)"] = y
        y += CGFloat(edge.value) * scale
      }
    }
    var links: [SankeyLinkBox] = []
    for edge in graph.edges {
      guard let from = boxes[edge.from], let to = boxes[edge.to] else { continue }
      let key = "\(edge.from)>\(edge.to)"
      links.append(
        SankeyLinkBox(
          from: edge.from, to: edge.to, value: edge.value,
          thickness: CGFloat(edge.value) * scale,
          x0: from.rect.maxX, x1: to.rect.minX,
          y0: sourceTop[key] ?? from.rect.minY, y1: targetTop[key] ?? to.rect.minY))
    }
    let nodes = columns.flatMap { column in (best[column] ?? []).compactMap { boxes[$0] } }
    return SankeyLayoutResult(
      nodes: nodes, links: links, scale: scale, crossings: bestCrossings)
  }

  // MARK: Sizing

  /// The minimum node height actually used: the configured one, lowered if the
  /// fullest column could not otherwise fit.
  static func minimumHeight(
    graph: SankeyGraph, config: SankeyLayoutConfig, columns: [Int]
  ) -> CGFloat {
    let largest = columns.map { graph.nodes(inColumn: $0).count }.max() ?? 1
    let room = (config.height - config.nodePadding * CGFloat(max(0, largest - 1))) / CGFloat(largest)
    return max(1, min(config.minimumNodeHeight, room))
  }

  /// Points per dollar: the largest scale at which every column fits inside the
  /// height, counting minimum node heights and padding.
  static func scale(
    graph: SankeyGraph, config: SankeyLayoutConfig, minimum: CGFloat, columns: [Int]
  ) -> CGFloat {
    func fits(_ scale: CGFloat) -> Bool {
      for column in columns {
        let members = graph.nodes(inColumn: column)
        let stack =
          members.map { max(CGFloat($0.value) * scale, minimum) }.reduce(0, +)
          + config.nodePadding * CGFloat(max(0, members.count - 1))
        if stack > config.height + 0.0001 { return false }
      }
      return true
    }
    let maxColumnValue = columns.map { column in
      graph.nodes(inColumn: column).map(\.value).reduce(0, +)
    }.max() ?? 0
    guard maxColumnValue > 0 else { return 0 }
    var low: CGFloat = 0
    var high = config.height / CGFloat(maxColumnValue)
    if fits(high) { return high }
    for _ in 0..<48 {
      let mid = (low + high) / 2
      if fits(mid) { low = mid } else { high = mid }
    }
    return low
  }

  // MARK: Ordering

  /// Reorders `column` by the value-weighted mean position of the nodes it is
  /// linked to in `neighbour`. Ties keep value order.
  private static func reordered(
    graph: SankeyGraph, column: Int, neighbour: Int, order: [Int: [String]]
  ) -> [String] {
    let neighbourOrder = order[neighbour] ?? []
    var position: [String: Double] = [:]
    for (index, id) in neighbourOrder.enumerated() { position[id] = Double(index) }
    let current = order[column] ?? []
    var currentIndex: [String: Int] = [:]
    for (index, id) in current.enumerated() { currentIndex[id] = index }
    var weight: [String: (sum: Double, total: Double)] = [:]
    for edge in graph.edges {
      let own: String
      let other: String
      if currentIndex[edge.from] != nil, position[edge.to] != nil {
        own = edge.from
        other = edge.to
      } else if currentIndex[edge.to] != nil, position[edge.from] != nil {
        own = edge.to
        other = edge.from
      } else {
        continue
      }
      guard let neighbourPosition = position[other] else { continue }
      var entry = weight[own] ?? (0, 0)
      entry.sum += neighbourPosition * edge.value
      entry.total += edge.value
      weight[own] = entry
    }
    return current.sorted { lhs, rhs in
      let left = weight[lhs].map { $0.sum / $0.total } ?? Double(currentIndex[lhs] ?? 0)
      let right = weight[rhs].map { $0.sum / $0.total } ?? Double(currentIndex[rhs] ?? 0)
      if abs(left - right) > 1e-9 { return left < right }
      return (currentIndex[lhs] ?? 0) < (currentIndex[rhs] ?? 0)
    }
  }

  /// Link pairs between the same two neighbouring columns whose ends are in
  /// opposite order. Links that share a node never cross (they are stacked in
  /// the order of their other end), so they do not count.
  static func crossingCount(graph: SankeyGraph, order: [Int: [String]]) -> Int {
    var position: [String: Int] = [:]
    var column: [String: Int] = [:]
    for (columnIndex, ids) in order {
      for (index, id) in ids.enumerated() {
        position[id] = index
        column[id] = columnIndex
      }
    }
    let edges = graph.edges.filter { position[$0.from] != nil && position[$0.to] != nil }
    var crossings = 0
    for i in 0..<edges.count {
      for j in (i + 1)..<max(i + 1, edges.count) {
        let a = edges[i]
        let b = edges[j]
        guard column[a.from] == column[b.from], column[a.to] == column[b.to] else { continue }
        guard a.from != b.from, a.to != b.to else { continue }
        let sourceOrder = position[a.from, default: 0] < position[b.from, default: 0]
        let targetOrder = position[a.to, default: 0] < position[b.to, default: 0]
        if sourceOrder != targetOrder { crossings += 1 }
      }
    }
    return crossings
  }
}
