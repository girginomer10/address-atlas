import CoreGraphics
import Foundation

// MARK: - Layout math
//
// Pure geometry for the part-C1 chart views (map, ring, strip, grid, bubbles,
// rings in rings, list). Nothing here touches SwiftUI, the theme, or the
// clock, so the same input always gives the same rectangles, cells, circles
// and angles on macOS and iOS, and the unit tests can check the invariants
// (areas proportional and inside the bounds, cells summing to exactly 100,
// circles that do not overlap, angles that sum to 2 pi).

// MARK: Treemap

enum ChartKitTreemap {
  /// Squarified treemap (Bruls, Huizing, van Wijk). Returns one rectangle per
  /// value in the order the values were given; the rectangles tile `bounds`
  /// exactly and each one's area is `value / sum * bounds area`. Values that
  /// are zero, negative, or not finite get an empty rectangle at the origin of
  /// `bounds`. Callers pass values largest first for the best aspect ratios;
  /// the function sorts by value (ties by position) itself, so any order is
  /// laid out deterministically.
  static func layout(values: [Double], in bounds: CGRect) -> [CGRect] {
    var result = [CGRect](
      repeating: CGRect(x: bounds.minX, y: bounds.minY, width: 0, height: 0), count: values.count)
    guard bounds.width > 0, bounds.height > 0 else { return result }
    let usable = values.enumerated().filter { $0.element.isFinite && $0.element > 0 }
    let total = usable.reduce(0.0) { $0 + $1.element }
    guard total > 0 else { return result }
    let ordered = usable.sorted { lhs, rhs in
      if lhs.element != rhs.element { return lhs.element > rhs.element }
      return lhs.offset < rhs.offset
    }
    let scale = Double(bounds.width * bounds.height) / total
    let items = ordered.map { (index: $0.offset, area: $0.element * scale) }

    var remaining = bounds
    var row: [(index: Int, area: Double)] = []
    var cursor = 0
    while cursor < items.count {
      let item = items[cursor]
      let side = Double(min(remaining.width, remaining.height))
      if row.isEmpty || worstRatio(row + [item], side: side) <= worstRatio(row, side: side) {
        row.append(item)
        cursor += 1
      } else {
        place(row, in: &remaining, into: &result)
        row = []
      }
    }
    if !row.isEmpty { place(row, in: &remaining, into: &result) }
    return result
  }

  private static func worstRatio(_ row: [(index: Int, area: Double)], side: Double) -> Double {
    let sum = row.reduce(0.0) { $0 + $1.area }
    guard sum > 0, side > 0 else { return .infinity }
    let largest = row.map(\.area).max() ?? 0
    let smallest = row.map(\.area).min() ?? 0
    guard smallest > 0 else { return .infinity }
    return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
  }

  /// Lays one row along the shorter side of `remaining` and shrinks it.
  private static func place(
    _ row: [(index: Int, area: Double)], in remaining: inout CGRect, into result: inout [CGRect]
  ) {
    let sum = row.reduce(0.0) { $0 + $1.area }
    guard sum > 0 else { return }
    if remaining.width >= remaining.height {
      // A column on the left edge.
      let columnWidth = min(CGFloat(sum / Double(remaining.height)), remaining.width)
      var y = remaining.minY
      for (position, item) in row.enumerated() {
        let isLast = position == row.count - 1
        let height = isLast ? remaining.maxY - y : CGFloat(item.area / sum) * remaining.height
        result[item.index] = CGRect(x: remaining.minX, y: y, width: columnWidth, height: height)
        y += height
      }
      remaining = CGRect(
        x: remaining.minX + columnWidth, y: remaining.minY,
        width: remaining.width - columnWidth, height: remaining.height)
    } else {
      // A strip along the top edge.
      let stripHeight = min(CGFloat(sum / Double(remaining.width)), remaining.height)
      var x = remaining.minX
      for (position, item) in row.enumerated() {
        let isLast = position == row.count - 1
        let width = isLast ? remaining.maxX - x : CGFloat(item.area / sum) * remaining.width
        result[item.index] = CGRect(x: x, y: remaining.minY, width: width, height: stripHeight)
        x += width
      }
      remaining = CGRect(
        x: remaining.minX, y: remaining.minY + stripHeight,
        width: remaining.width, height: remaining.height - stripHeight)
    }
  }
}

// MARK: Waffle

enum ChartKitWaffle {
  static let cellCount = 100

  /// Largest-remainder allocation of `cells` cells to the shares, so the
  /// counts always sum to exactly `cells` when there is anything to show.
  /// Shares are relative (they need not sum to 1). Ties in the fractional part
  /// go to the larger share, then to the earlier index. A share that is zero,
  /// negative, or not finite gets no cells.
  static func allocate(shares: [Double], cells: Int = cellCount) -> [Int] {
    let weights = shares.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    let total = weights.reduce(0, +)
    guard total > 0, cells > 0 else { return [Int](repeating: 0, count: shares.count) }
    let quotas = weights.map { $0 / total * Double(cells) }
    var counts = quotas.map { Int($0.rounded(.down)) }
    var remainder = cells - counts.reduce(0, +)
    let order = quotas.indices.sorted { lhs, rhs in
      let lhsFraction = quotas[lhs] - Double(counts[lhs])
      let rhsFraction = quotas[rhs] - Double(counts[rhs])
      if lhsFraction != rhsFraction { return lhsFraction > rhsFraction }
      if weights[lhs] != weights[rhs] { return weights[lhs] > weights[rhs] }
      return lhs < rhs
    }
    var position = 0
    while remainder > 0, position < order.count {
      // Only slices that exist can receive a cell.
      if weights[order[position]] > 0 {
        counts[order[position]] += 1
        remainder -= 1
      }
      position += 1
    }
    return counts
  }

  /// The slice index that owns each of the cells, in reading order (left to
  /// right, then top to bottom).
  static func owners(counts: [Int]) -> [Int] {
    var owners: [Int] = []
    for (index, count) in counts.enumerated() {
      owners.append(contentsOf: [Int](repeating: index, count: max(count, 0)))
    }
    return owners
  }
}

// MARK: Circle packing

struct ChartKitCircle: Equatable {
  var center: CGPoint
  var radius: CGFloat
}

enum ChartKitBubblePacking {
  /// Deterministic circle packing with area proportional to value.
  ///
  /// Circles are placed largest first. The first sits at the origin, the second
  /// beside it, and every later one in the tangent position against two placed
  /// circles that is closest to the origin (measured on an ellipse with the
  /// bounds' aspect ratio, so a wide area fills sideways) and overlaps nothing.
  /// The whole cluster is then scaled to fit `bounds` and centred in it.
  ///
  /// `gap` is the clear distance kept between circles after scaling, in
  /// points. The returned radii are the drawn radii. A value that is zero,
  /// negative, or not finite gets a zero-radius circle at the centre of
  /// `bounds`. The result is in the order of `values`.
  static func pack(values: [Double], in bounds: CGRect, gap: CGFloat = 0) -> [ChartKitCircle] {
    let centre = CGPoint(x: bounds.midX, y: bounds.midY)
    var result = [ChartKitCircle](
      repeating: ChartKitCircle(center: centre, radius: 0), count: values.count)
    guard bounds.width > 0, bounds.height > 0 else { return result }
    let usable = values.enumerated().filter { $0.element.isFinite && $0.element > 0 }
    guard let largest = usable.map(\.element).max() else { return result }
    let ordered = usable.sorted { lhs, rhs in
      if lhs.element != rhs.element { return lhs.element > rhs.element }
      return lhs.offset < rhs.offset
    }
    // Unit space: the largest circle has radius 1. Packing uses radii padded by
    // `padding` so that, once scaled, circles are at least `gap` apart.
    let unitRadii = ordered.map { sqrt($0.element / largest) }
    let aspect = max(0.25, min(4, Double(bounds.width / bounds.height)))

    // The padding in unit space depends on the final scale, which depends on
    // the padding. Two passes converge well enough: pack unpadded to estimate
    // the scale, then pack again with the padding that scale implies.
    var padding = 0.0
    var placed = place(radii: unitRadii, padding: padding, aspect: aspect)
    for _ in 0..<2 where gap > 0 {
      let scale = fitScale(placed: placed, radii: unitRadii, bounds: bounds)
      guard scale > 0 else { break }
      padding = Double(gap) / Double(scale) / 2
      placed = place(radii: unitRadii, padding: padding, aspect: aspect)
    }
    let scale = fitScale(placed: placed, radii: unitRadii, bounds: bounds)
    guard scale > 0 else { return result }

    // Centre the cluster's bounding box in `bounds`.
    var minX = Double.infinity
    var maxX = -Double.infinity
    var minY = Double.infinity
    var maxY = -Double.infinity
    for (position, point) in placed.enumerated() {
      minX = min(minX, point.x - unitRadii[position])
      maxX = max(maxX, point.x + unitRadii[position])
      minY = min(minY, point.y - unitRadii[position])
      maxY = max(maxY, point.y + unitRadii[position])
    }
    let midX = (minX + maxX) / 2
    let midY = (minY + maxY) / 2
    for (position, item) in ordered.enumerated() {
      result[item.offset] = ChartKitCircle(
        center: CGPoint(
          x: bounds.midX + CGFloat((placed[position].x - midX)) * scale,
          y: bounds.midY + CGFloat((placed[position].y - midY)) * scale),
        radius: CGFloat(unitRadii[position]) * scale
      )
    }
    return result
  }

  private static func fitScale(
    placed: [(x: Double, y: Double)], radii: [Double], bounds: CGRect
  ) -> CGFloat {
    var minX = Double.infinity
    var maxX = -Double.infinity
    var minY = Double.infinity
    var maxY = -Double.infinity
    for (position, point) in placed.enumerated() {
      minX = min(minX, point.x - radii[position])
      maxX = max(maxX, point.x + radii[position])
      minY = min(minY, point.y - radii[position])
      maxY = max(maxY, point.y + radii[position])
    }
    let width = maxX - minX
    let height = maxY - minY
    guard width > 0, height > 0 else { return 0 }
    return CGFloat(min(Double(bounds.width) / width, Double(bounds.height) / height))
  }

  /// Positions for circles of the given unit radii (largest first), each
  /// padded by `padding` for the purpose of collisions.
  private static func place(radii: [Double], padding: Double, aspect: Double) -> [(
    x: Double, y: Double
  )] {
    var positions: [(x: Double, y: Double)] = []
    var padded: [Double] = []
    for radius in radii {
      let grown = radius + padding
      defer { padded.append(grown) }
      if positions.isEmpty {
        positions.append((0, 0))
        continue
      }
      if positions.count == 1 {
        positions.append((padded[0] + grown, 0))
        continue
      }
      var best: (x: Double, y: Double)?
      var bestScore = Double.infinity
      for first in 0..<positions.count {
        for second in (first + 1)..<positions.count {
          for candidate in tangentPositions(
            positions[first], padded[first], positions[second], padded[second], grown)
          {
            guard
              !positions.enumerated().contains(where: { index, other in
                hypot(candidate.x - other.x, candidate.y - other.y)
                  < padded[index] + grown - 1e-9
              })
            else { continue }
            let score = pow(candidate.x / aspect, 2) + pow(candidate.y, 2)
            if score < bestScore - 1e-12 {
              bestScore = score
              best = candidate
            }
          }
        }
      }
      if let best {
        positions.append(best)
      } else {
        // Cannot happen for a valid cluster; keep the circle clear of the others.
        let farthest = positions.enumerated().map { $0.element.x + padded[$0.offset] }.max() ?? 0
        positions.append((farthest + grown, 0))
      }
    }
    return positions
  }

  /// Centres of a circle of radius `r` tangent to both circle `a` and circle `b`.
  private static func tangentPositions(
    _ a: (x: Double, y: Double), _ ra: Double,
    _ b: (x: Double, y: Double), _ rb: Double,
    _ r: Double
  ) -> [(x: Double, y: Double)] {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let distance = hypot(dx, dy)
    let da = ra + r
    let db = rb + r
    guard distance > 1e-12, distance <= da + db, distance >= abs(da - db) else { return [] }
    let along = (da * da - db * db + distance * distance) / (2 * distance)
    let heightSquared = da * da - along * along
    guard heightSquared >= 0 else { return [] }
    let height = sqrt(heightSquared)
    let baseX = a.x + along * dx / distance
    let baseY = a.y + along * dy / distance
    let offsetX = -dy / distance * height
    let offsetY = dx / distance * height
    return [(baseX + offsetX, baseY + offsetY), (baseX - offsetX, baseY - offsetY)]
  }
}

// MARK: Arcs (ring and sunburst)

/// An angular span in radians, measured clockwise from 12 o'clock.
struct ChartKitArc: Equatable {
  var start: Double
  var end: Double
  var span: Double { end - start }
  var middle: Double { (start + end) / 2 }
}

enum ChartKitSunburst {
  static let fullTurn = 2 * Double.pi

  /// Tiles `[from, from + span]` with one arc per value, in proportion to the
  /// values. Values that are zero, negative, or not finite get a zero-width
  /// arc. The last positive arc ends exactly at `from + span`.
  static func tile(values: [Double], from start: Double = 0, span: Double = fullTurn) -> [ChartKitArc] {
    let weights = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    let total = weights.reduce(0, +)
    guard total > 0 else {
      return values.map { _ in ChartKitArc(start: start, end: start) }
    }
    let lastPositive = weights.lastIndex { $0 > 0 }
    var cursor = start
    var arcs: [ChartKitArc] = []
    for (index, weight) in weights.enumerated() {
      let end = index == lastPositive ? start + span : cursor + weight / total * span
      arcs.append(ChartKitArc(start: cursor, end: end))
      cursor = end
    }
    return arcs
  }

  /// The inner ring (one arc per parent) and, for every parent, the outer
  /// arcs of its children, which tile exactly the parent's span.
  static func rings(parents: [Double], children: [[Double]]) -> (
    inner: [ChartKitArc], outer: [[ChartKitArc]]
  ) {
    let inner = tile(values: parents)
    var outer: [[ChartKitArc]] = []
    for (index, arc) in inner.enumerated() {
      let values = index < children.count ? children[index] : []
      outer.append(tile(values: values, from: arc.start, span: arc.span))
    }
    return (inner, outer)
  }

  /// The arc shrunk by `gapAngle / 2` at both ends, or the whole arc when it
  /// is too narrow to shrink or is the only one (a full circle needs no gap).
  static func inset(_ arc: ChartKitArc, gapAngle: Double) -> ChartKitArc {
    guard arc.span < fullTurn - 1e-9 else { return arc }
    let half = min(gapAngle / 2, arc.span * 0.25)
    return ChartKitArc(start: arc.start + half, end: arc.end - half)
  }
}

// MARK: Strip

enum ChartKitStrip {
  /// Segment widths for a bar of `width` points with `gap` between segments.
  /// The widths plus the gaps always add up to `width` when there is more than
  /// one visible segment; a zero share gets zero width and no gap.
  static func widths(shares: [Double], width: CGFloat, gap: CGFloat) -> [CGFloat] {
    let weights = shares.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    let total = weights.reduce(0, +)
    let visible = weights.filter { $0 > 0 }.count
    guard total > 0, visible > 0, width > 0 else { return weights.map { _ in 0 } }
    let usable = max(0, width - gap * CGFloat(visible - 1))
    return weights.map { CGFloat($0 / total) * usable }
  }
}

// MARK: Label budget

/// Rough text-fit estimates, used to decide *which* labels are worth offering
/// (and which slices need a legend entry instead). The views still lay every
/// label out with `ViewThatFits`, so the real measurement, including Dynamic
/// Type, decides what is drawn; these only avoid offering labels that cannot
/// possibly fit.
enum ChartKitLabelBudget {
  /// Average glyph advance as a fraction of the point size, for the themed
  /// proportional and monospaced faces alike (a little generous).
  static let averageAdvance: CGFloat = 0.62

  static func width(characters: Int, fontSize: CGFloat) -> CGFloat {
    CGFloat(max(characters, 0)) * fontSize * averageAdvance
  }

  static func fits(characters: Int, fontSize: CGFloat, in available: CGFloat) -> Bool {
    width(characters: characters, fontSize: fontSize) <= available
  }
}
