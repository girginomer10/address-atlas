import CoreGraphics
import Foundation

// Weighted Voronoi treemap (the "atlas map"): every item becomes a convex cell
// whose area is proportional to its value, inside a convex outer boundary.
//
// Method (Balzer and Deussen, "Voronoi treemaps"): cells are the cells of a
// power diagram, a Voronoi diagram in which each site has an additive weight.
// A larger weight grows the site's cell. The solver alternates
//   - weight adaptation: each weight moves by the area shortfall divided by how
//     fast the cell's area responds to its weight (the sum over its edges of
//     length / (2 * distance to the neighbour)), and
//   - Lloyd relaxation: each site moves to its cell's centroid, which keeps
//     cells compact.
// Everything is deterministic: sites start at positions derived from a stable
// hash of the item key (so an item starts in the same place on every scan), and
// the iteration counts are fixed. It stops early once every cell's area is
// within `targetError` of its share.
//
// Cost is O(n^2) clips per diagram; 30 items take a few milliseconds.

// MARK: - Result types

struct PowerDiagramItem: Equatable {
  let key: String
  let value: Double
}

struct PowerDiagramCell: Equatable, Identifiable {
  var id: String { key }
  let key: String
  let value: Double
  /// Convex polygon, in the boundary's coordinate space.
  let polygon: [CGPoint]
  let site: CGPoint
  let area: Double
  let targetArea: Double

  var relativeError: Double {
    targetArea > 0 ? abs(area - targetArea) / targetArea : 0
  }
}

struct PowerDiagramResult: Equatable {
  let cells: [PowerDiagramCell]
  /// Largest relative area error over all cells.
  let maximumError: Double
  /// Diagram evaluations performed.
  let evaluations: Int
}

struct PowerDiagramConfig: Equatable {
  /// Stop once every cell is within this fraction of its target area.
  var targetError: Double = 0.02
  /// Lloyd relaxation rounds.
  var relaxationRounds: Int = 7
  /// Weight adaptation steps per round.
  var adaptationSteps: Int = 12
  /// Extra weight steps after the last move, until the target is reached.
  var finalSteps: Int = 30
  /// Mixed into the item hash; change it to get a different (still
  /// deterministic) arrangement.
  var seed: UInt64 = 0
}

// MARK: - Solver

enum PowerDiagramTreemap {
  /// Lays out `items` (positive values only; others are ignored) inside the
  /// convex `boundary`. Cells appear in input order.
  static func layout(
    items: [PowerDiagramItem],
    boundary: [CGPoint],
    config: PowerDiagramConfig = PowerDiagramConfig()
  ) -> PowerDiagramResult {
    let items = items.filter { $0.value.isFinite && $0.value > 0 }
    let boundaryArea = ConvexPolygon.area(boundary)
    guard boundary.count >= 3, boundaryArea > 0, !items.isEmpty else {
      return PowerDiagramResult(cells: [], maximumError: 0, evaluations: 0)
    }
    if items.count == 1 {
      let only = items[0]
      return PowerDiagramResult(
        cells: [
          PowerDiagramCell(
            key: only.key, value: only.value, polygon: boundary,
            site: ConvexPolygon.centroid(boundary), area: boundaryArea, targetArea: boundaryArea)
        ],
        maximumError: 0, evaluations: 0)
    }

    let totalValue = items.map(\.value).sorted().reduce(0, +)
    let targets = items.map { boundaryArea * $0.value / totalValue }
    let typicalRadiusSquared = boundaryArea / Double(items.count)
    var sites = initialSites(items: items, boundary: boundary, seed: config.seed)
    var weights = [Double](repeating: 0, count: items.count)
    var evaluations = 0

    func evaluate() -> [CellGeometry] {
      evaluations += 1
      return diagram(sites: sites, weights: weights, boundary: boundary)
    }

    func maximumError(_ geometry: [CellGeometry]) -> Double {
      var worst = 0.0
      for (index, cell) in geometry.enumerated() {
        worst = max(worst, abs(cell.area - targets[index]) / targets[index])
      }
      return worst
    }

    func adaptWeights(_ geometry: [CellGeometry]) {
      var delta = [Double](repeating: 0, count: items.count)
      for (index, cell) in geometry.enumerated() {
        var response = 0.0
        for (neighbour, length) in cell.edgeLengths {
          let dx = sites[index].x - sites[neighbour].x
          let dy = sites[index].y - sites[neighbour].y
          let distance = (dx * dx + dy * dy).squareRoot()
          if distance > 1e-9 { response += length / (2 * distance) }
        }
        let shortfall = targets[index] - cell.area
        if response > 1e-9 {
          delta[index] = 0.8 * shortfall / response
        } else {
          // An empty cell (or one with no neighbours): push its weight up (or
          // down) by a fraction of the typical cell radius squared.
          delta[index] = shortfall > 0 ? typicalRadiusSquared * 0.5 : -typicalRadiusSquared * 0.25
        }
        let limit = typicalRadiusSquared * 1.5
        delta[index] = min(max(delta[index], -limit), limit)
      }
      var mean = 0.0
      for index in 0..<weights.count {
        weights[index] += delta[index]
        mean += weights[index]
      }
      mean /= Double(weights.count)
      for index in 0..<weights.count { weights[index] -= mean }
    }

    var geometry = evaluate()
    for round in 0..<config.relaxationRounds {
      // Adapt, then relax. The last round skips the move so the final weights
      // match the final sites.
      for _ in 0..<config.adaptationSteps {
        if maximumError(geometry) <= config.targetError / 2 { break }
        adaptWeights(geometry)
        geometry = evaluate()
      }
      if round == config.relaxationRounds - 1 { break }
      for index in 0..<sites.count where geometry[index].area > 0 {
        sites[index] = geometry[index].centroid
      }
      geometry = evaluate()
    }
    for _ in 0..<config.finalSteps {
      if maximumError(geometry) <= config.targetError { break }
      adaptWeights(geometry)
      geometry = evaluate()
    }

    var cells: [PowerDiagramCell] = []
    for (index, item) in items.enumerated() {
      cells.append(
        PowerDiagramCell(
          key: item.key, value: item.value, polygon: geometry[index].polygon,
          site: sites[index], area: geometry[index].area, targetArea: targets[index]))
    }
    return PowerDiagramResult(
      cells: cells, maximumError: maximumError(geometry), evaluations: evaluations)
  }

  // MARK: Geometry

  private struct CellGeometry {
    var polygon: [CGPoint]
    var area: Double
    var centroid: CGPoint
    /// Length of the cell's border shared with each neighbouring site.
    var edgeLengths: [(Int, Double)]
  }

  private struct TaggedVertex {
    var point: CGPoint
    /// Index of the neighbouring site the edge from this vertex to the next one
    /// borders, or -1 for the outer boundary.
    var tag: Int
  }

  private static func diagram(
    sites: [CGPoint], weights: [Double], boundary: [CGPoint]
  ) -> [CellGeometry] {
    var result: [CellGeometry] = []
    result.reserveCapacity(sites.count)
    let count = sites.count
    for i in 0..<count {
      var polygon = boundary.map { TaggedVertex(point: $0, tag: -1) }
      let si = sites[i]
      for j in 0..<count where j != i {
        let sj = sites[j]
        // Keep a*x + b*y <= c: the points at least as close (in power distance)
        // to site i as to site j.
        let a = 2 * Double(sj.x - si.x)
        let b = 2 * Double(sj.y - si.y)
        let c =
          Double(sj.x * sj.x + sj.y * sj.y) - Double(si.x * si.x + si.y * si.y) + weights[i]
          - weights[j]
        polygon = clip(polygon, a: a, b: b, c: c, tag: j)
        if polygon.count < 3 {
          polygon = []
          break
        }
      }
      let points = polygon.map(\.point)
      var lengths: [Int: Double] = [:]
      for index in 0..<polygon.count where polygon[index].tag >= 0 {
        let next = polygon[(index + 1) % polygon.count].point
        let here = polygon[index].point
        lengths[polygon[index].tag, default: 0] += Double(hypot(next.x - here.x, next.y - here.y))
      }
      let area = ConvexPolygon.area(points)
      result.append(
        CellGeometry(
          polygon: points, area: area,
          centroid: area > 0 ? ConvexPolygon.centroid(points) : si,
          edgeLengths: lengths.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
    }
    return result
  }

  /// Sutherland-Hodgman clip of a convex polygon against one half-plane.
  private static func clip(
    _ polygon: [TaggedVertex], a: Double, b: Double, c: Double, tag: Int
  ) -> [TaggedVertex] {
    guard !polygon.isEmpty else { return [] }
    var output: [TaggedVertex] = []
    output.reserveCapacity(polygon.count + 2)
    let count = polygon.count
    for index in 0..<count {
      let current = polygon[index]
      let next = polygon[(index + 1) % count]
      let currentSide = a * Double(current.point.x) + b * Double(current.point.y) - c
      let nextSide = a * Double(next.point.x) + b * Double(next.point.y) - c
      let currentInside = currentSide <= 0
      let nextInside = nextSide <= 0
      if currentInside {
        if nextInside {
          output.append(current)
        } else {
          output.append(current)
          output.append(
            TaggedVertex(
              point: intersection(current.point, next.point, currentSide, nextSide), tag: tag))
        }
      } else if nextInside {
        output.append(
          TaggedVertex(
            point: intersection(current.point, next.point, currentSide, nextSide), tag: current.tag))
      }
    }
    return output
  }

  private static func intersection(
    _ p: CGPoint, _ q: CGPoint, _ sp: Double, _ sq: Double
  ) -> CGPoint {
    let denominator = sp - sq
    guard abs(denominator) > 1e-15 else { return p }
    let t = CGFloat(sp / denominator)
    return CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
  }

  // MARK: Seeds

  /// Starting sites: a hash of the key places each item in the boundary's
  /// bounding box; sites outside the boundary slide toward its centroid, and
  /// coinciding sites are nudged apart.
  static func initialSites(items: [PowerDiagramItem], boundary: [CGPoint], seed: UInt64)
    -> [CGPoint]
  {
    let box = ConvexPolygon.boundingBox(boundary)
    let centre = ConvexPolygon.centroid(boundary)
    var sites: [CGPoint] = []
    for (index, item) in items.enumerated() {
      let hash = stableHash(item.key, seed: seed)
      let fx = unit(hash & 0xFFFF_FFFF)
      let fy = unit(hash >> 32)
      var point = CGPoint(
        x: box.minX + box.width * (0.12 + 0.76 * fx),
        y: box.minY + box.height * (0.12 + 0.76 * fy))
      var shrink: CGFloat = 1
      while !ConvexPolygon.contains(boundary, point) && shrink > 0.01 {
        shrink *= 0.8
        point = CGPoint(
          x: centre.x + (point.x - centre.x) * 0.8, y: centre.y + (point.y - centre.y) * 0.8)
      }
      for existing in sites where hypot(existing.x - point.x, existing.y - point.y) < 1e-3 {
        point.x += CGFloat(index + 1) * 0.37
        point.y += CGFloat(index + 1) * 0.21
      }
      sites.append(point)
    }
    return sites
  }

  private static func unit(_ value: UInt64) -> CGFloat {
    CGFloat(Double(value) / Double(UInt32.max))
  }

  /// FNV-1a with a final avalanche, stable across launches and platforms.
  static func stableHash(_ text: String, seed: UInt64) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    hash ^= hash >> 33
    hash = hash &* 0xff51_afd7_ed55_8ccd
    hash ^= hash >> 33
    hash = hash &* 0xc4ce_b9fe_1a85_ec53
    hash ^= hash >> 33
    return hash
  }
}

// MARK: - Convex polygon helpers

enum ConvexPolygon {
  /// A rounded rectangle as a convex polygon (clockwise on screen). A radius
  /// of zero gives the plain rectangle.
  static func roundedRectangle(
    _ rect: CGRect, cornerRadius: CGFloat, segmentsPerCorner: Int = 7
  ) -> [CGPoint] {
    let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
    guard radius > 0.5, segmentsPerCorner >= 1 else {
      return [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
      ]
    }
    // Corner centres and the angle each arc starts at (screen coordinates).
    let corners: [(CGPoint, Double)] = [
      (CGPoint(x: rect.minX + radius, y: rect.minY + radius), .pi),
      (CGPoint(x: rect.maxX - radius, y: rect.minY + radius), 1.5 * .pi),
      (CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), 0),
      (CGPoint(x: rect.minX + radius, y: rect.maxY - radius), 0.5 * .pi),
    ]
    var points: [CGPoint] = []
    for (centre, start) in corners {
      for step in 0...segmentsPerCorner {
        let angle = start + (.pi / 2) * Double(step) / Double(segmentsPerCorner)
        points.append(
          CGPoint(
            x: centre.x + radius * CGFloat(cos(angle)),
            y: centre.y + radius * CGFloat(sin(angle))))
      }
    }
    return points
  }

  /// Unsigned area (shoelace).
  static func area(_ polygon: [CGPoint]) -> Double {
    guard polygon.count >= 3 else { return 0 }
    var sum = 0.0
    for index in 0..<polygon.count {
      let p = polygon[index]
      let q = polygon[(index + 1) % polygon.count]
      sum += Double(p.x * q.y - q.x * p.y)
    }
    return abs(sum) / 2
  }

  static func centroid(_ polygon: [CGPoint]) -> CGPoint {
    guard polygon.count >= 3 else {
      return polygon.first ?? .zero
    }
    var signedArea = 0.0
    var cx = 0.0
    var cy = 0.0
    for index in 0..<polygon.count {
      let p = polygon[index]
      let q = polygon[(index + 1) % polygon.count]
      let cross = Double(p.x * q.y - q.x * p.y)
      signedArea += cross
      cx += Double(p.x + q.x) * cross
      cy += Double(p.y + q.y) * cross
    }
    guard abs(signedArea) > 1e-12 else {
      let sum = polygon.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
      return CGPoint(x: sum.x / CGFloat(polygon.count), y: sum.y / CGFloat(polygon.count))
    }
    return CGPoint(x: cx / (3 * signedArea), y: cy / (3 * signedArea))
  }

  static func boundingBox(_ polygon: [CGPoint]) -> CGRect {
    guard let first = polygon.first else { return .zero }
    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y
    for point in polygon {
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// +1 when the vertices run counter-clockwise in a y-up system (clockwise on
  /// screen), -1 otherwise.
  private static func orientation(_ polygon: [CGPoint]) -> Double {
    var sum = 0.0
    for index in 0..<polygon.count {
      let p = polygon[index]
      let q = polygon[(index + 1) % polygon.count]
      sum += Double(p.x * q.y - q.x * p.y)
    }
    return sum >= 0 ? 1 : -1
  }

  /// Distance from `point` to each edge's line, positive inside, for a convex
  /// polygon. The smallest is how far the point is from the border.
  static func edgeDistances(_ polygon: [CGPoint], _ point: CGPoint) -> [Double] {
    let orient = orientation(polygon)
    var distances: [Double] = []
    distances.reserveCapacity(polygon.count)
    for index in 0..<polygon.count {
      let p = polygon[index]
      let q = polygon[(index + 1) % polygon.count]
      let dx = Double(q.x - p.x)
      let dy = Double(q.y - p.y)
      let length = (dx * dx + dy * dy).squareRoot()
      guard length > 1e-12 else { continue }
      // Interior is on the left of each edge for positive orientation.
      let cross = dx * Double(point.y - p.y) - dy * Double(point.x - p.x)
      distances.append(orient * cross / length)
    }
    return distances
  }

  static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
    guard polygon.count >= 3 else { return false }
    return (edgeDistances(polygon, point).min() ?? -1) >= -1e-6
  }

  /// The polygon moved inward by `distance` on every side, or nil when nothing
  /// is left.
  static func inset(_ polygon: [CGPoint], by distance: CGFloat) -> [CGPoint]? {
    guard polygon.count >= 3 else { return nil }
    guard distance > 0 else { return polygon }
    let orient = orientation(polygon)
    var result = polygon
    for index in 0..<polygon.count {
      let p = polygon[index]
      let q = polygon[(index + 1) % polygon.count]
      let dx = Double(q.x - p.x)
      let dy = Double(q.y - p.y)
      let length = (dx * dx + dy * dy).squareRoot()
      guard length > 1e-12 else { continue }
      // Unit normal pointing out of the polygon.
      let nx = orient * dy / length
      let ny = -orient * dx / length
      let limit = nx * Double(p.x) + ny * Double(p.y) - Double(distance)
      result = clip(result, nx: nx, ny: ny, limit: limit)
      if result.count < 3 { return nil }
    }
    return result
  }

  private static func clip(_ polygon: [CGPoint], nx: Double, ny: Double, limit: Double)
    -> [CGPoint]
  {
    var output: [CGPoint] = []
    let count = polygon.count
    for index in 0..<count {
      let current = polygon[index]
      let next = polygon[(index + 1) % count]
      let currentSide = nx * Double(current.x) + ny * Double(current.y) - limit
      let nextSide = nx * Double(next.x) + ny * Double(next.y) - limit
      if currentSide <= 0 {
        output.append(current)
        if nextSide > 0 { output.append(crossing(current, next, currentSide, nextSide)) }
      } else if nextSide <= 0 {
        output.append(crossing(current, next, currentSide, nextSide))
      }
    }
    return output
  }

  private static func crossing(_ p: CGPoint, _ q: CGPoint, _ sp: Double, _ sq: Double) -> CGPoint {
    let denominator = sp - sq
    guard abs(denominator) > 1e-15 else { return p }
    let t = CGFloat(sp / denominator)
    return CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
  }

  /// Centre of the largest circle inside the polygon (the pole of
  /// inaccessibility) and its radius. The distance to the border is concave
  /// inside a convex polygon, so a shrinking pattern search finds the maximum.
  static func pole(_ polygon: [CGPoint]) -> (center: CGPoint, radius: Double) {
    guard polygon.count >= 3 else { return (polygon.first ?? .zero, 0) }
    func depth(_ point: CGPoint) -> Double { edgeDistances(polygon, point).min() ?? -1 }
    let box = boundingBox(polygon)
    var best = centroid(polygon)
    var bestDepth = depth(best)
    // Coarse grid first, so a thin, bent cell does not trap the search.
    let steps = 8
    for ix in 0...steps {
      for iy in 0...steps {
        let candidate = CGPoint(
          x: box.minX + box.width * CGFloat(ix) / CGFloat(steps),
          y: box.minY + box.height * CGFloat(iy) / CGFloat(steps))
        let value = depth(candidate)
        if value > bestDepth {
          best = candidate
          bestDepth = value
        }
      }
    }
    var step = max(box.width, box.height) / 8
    while step > 0.05 {
      var improved = false
      for dx in [-1.0, 0.0, 1.0] {
        for dy in [-1.0, 0.0, 1.0] where dx != 0 || dy != 0 {
          let candidate = CGPoint(x: best.x + CGFloat(dx) * step, y: best.y + CGFloat(dy) * step)
          let value = depth(candidate)
          if value > bestDepth + 1e-9 {
            best = candidate
            bestDepth = value
            improved = true
          }
        }
      }
      if !improved { step /= 2 }
    }
    return (best, bestDepth)
  }

  /// The centre at which a `size` rectangle, kept `margin` away from the
  /// border, fits inside the polygon, or nil when it cannot fit. Searches from
  /// the pole of inaccessibility.
  static func labelCenter(for polygon: [CGPoint], size: CGSize, margin: CGFloat = 2) -> CGPoint? {
    guard polygon.count >= 3 else { return nil }
    let halfWidth = Double(size.width) / 2 + Double(margin)
    let halfHeight = Double(size.height) / 2 + Double(margin)
    let orient = orientation(polygon)
    // Slack of a rectangle centred at `point`: the smallest distance of any of
    // its corners to any edge. Non-negative means it fits.
    func slack(_ point: CGPoint) -> Double {
      var worst = Double.infinity
      for index in 0..<polygon.count {
        let p = polygon[index]
        let q = polygon[(index + 1) % polygon.count]
        let dx = Double(q.x - p.x)
        let dy = Double(q.y - p.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-12 else { continue }
        let nx = -orient * dy / length  // inward unit normal
        let ny = orient * dx / length
        let cross = dx * Double(point.y - p.y) - dy * Double(point.x - p.x)
        let centreDistance = orient * cross / length
        let reach = abs(nx) * halfWidth + abs(ny) * halfHeight
        worst = min(worst, centreDistance - reach)
      }
      return worst
    }
    var best = pole(polygon).center
    var bestSlack = slack(best)
    var step = max(boundingBox(polygon).width, boundingBox(polygon).height) / 6
    while step > 0.05 {
      var improved = false
      for dx in [-1.0, 0.0, 1.0] {
        for dy in [-1.0, 0.0, 1.0] where dx != 0 || dy != 0 {
          let candidate = CGPoint(x: best.x + CGFloat(dx) * step, y: best.y + CGFloat(dy) * step)
          let value = slack(candidate)
          if value > bestSlack + 1e-9 {
            best = candidate
            bestSlack = value
            improved = true
          }
        }
      }
      if !improved { step /= 2 }
    }
    return bestSlack >= 0 ? best : nil
  }
}
