import AddressAtlasCore
import CoreGraphics
import Foundation

// Pure model behind `AtlasMapChartView`: which slices become cells, whether the
// map nests networks around coins, the geometry, hit tests, label planning and
// the plain-language strings. No SwiftUI, so it is tested without rendering.

/// Whether the map groups coin cells into network regions.
enum AtlasMapNesting: Equatable {
  /// One flat set of cells.
  case off
  /// Nest by network when it stays legible; otherwise flat.
  case automatic
}

struct AtlasMapSlice: Equatable, Identifiable {
  static let otherKey = "__other__"

  let id: String
  let key: String
  let label: String
  let value: Double
  /// Of the whole map's value, 0...1.
  let share: Double
  let isOther: Bool

  init(key: String, label: String, value: Double, share: Double, isOther: Bool = false) {
    id = key
    self.key = key
    self.label = label
    self.value = value
    self.share = share
    self.isOther = isOther
  }

  init(_ slice: PortfolioSlice) {
    self.init(key: slice.key, label: slice.label, value: slice.valueUsd, share: slice.share)
  }
}

struct AtlasMapRegion: Equatable, Identifiable {
  var id: String { key }
  let key: String
  let label: String
  let value: Double
  let share: Double
  let children: [AtlasMapSlice]
}

/// What the map shows, before any geometry.
struct AtlasMapPlan: Equatable {
  let grouping: PortfolioGrouping
  let total: Double
  /// Cells of a flat map, largest first. Empty when nested.
  let slices: [AtlasMapSlice]
  /// Network regions of a nested map, largest first. Empty when flat.
  let regions: [AtlasMapRegion]
  let unpricedCount: Int

  var isNested: Bool { !regions.isEmpty }
  var isEmpty: Bool { slices.isEmpty && regions.isEmpty }
  var cellCount: Int { isNested ? regions.map(\.children.count).reduce(0, +) : slices.count }
}

struct AtlasMapCell: Equatable, Identifiable {
  /// `key`, or `region>key` inside a region.
  let id: String
  let key: String
  let label: String
  let value: Double
  /// Of the whole map's value.
  let share: Double
  let isOther: Bool
  let regionKey: String?
  let regionLabel: String?
  let polygon: [CGPoint]
  /// Centre of the largest circle inside the cell.
  let pole: CGPoint
  let poleRadius: Double
  let area: Double
  let targetArea: Double
}

struct AtlasMapRegionShape: Equatable, Identifiable {
  var id: String { key }
  let key: String
  let label: String
  let value: Double
  let share: Double
  let polygon: [CGPoint]
}

struct AtlasMapLayout: Equatable {
  let boundary: [CGPoint]
  let cells: [AtlasMapCell]
  let regions: [AtlasMapRegionShape]
  /// Largest relative area error over every diagram that was solved.
  let maximumError: Double

  func cell(_ id: String) -> AtlasMapCell? { cells.first { $0.id == id } }
}

struct AtlasMapKey: Equatable {
  var width: CGFloat
  var height: CGFloat
  var compact: Bool
  var cornerRadius: CGFloat
}

enum AtlasMapModel {
  // MARK: Slices

  /// Slices under this share are folded into "Other" when two or more are that
  /// small.
  static func minimumShare(compact: Bool) -> Double { compact ? 0.03 : 0.01 }

  /// Most cells, counting the "Other" cell.
  static func maximumCells(compact: Bool) -> Int { compact ? 10 : 24 }

  /// Folds the smallest slices into one "Other" slice when there are more than
  /// `maximumCount`, or when two or more are under `minimumShare`. A single
  /// small slice stays: "Other" holding one slice would say less than the slice.
  /// Zero and negative values are dropped. The order of the rest is kept.
  static func folding(
    _ slices: [AtlasMapSlice], minimumShare: Double, maximumCount: Int
  ) -> [AtlasMapSlice] {
    let valued = slices.filter { $0.value.isFinite && $0.value > 0 }
    let ordered = valued.sorted { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      if lhs.label != rhs.label { return lhs.label < rhs.label }
      return lhs.key < rhs.key
    }
    let tiny = ordered.filter { $0.share < minimumShare }.count
    let capacityFold = ordered.count > maximumCount ? ordered.count - maximumCount + 1 : 0
    let fold = max(capacityFold, tiny >= 2 ? tiny : 0)
    guard fold >= 2 else { return ordered }
    let kept = ordered.dropLast(fold)
    let folded = ordered.suffix(fold)
    let value = folded.map(\.value).sorted().reduce(0, +)
    let share = folded.map(\.share).sorted().reduce(0, +)
    return Array(kept)
      + [
        AtlasMapSlice(
          key: AtlasMapSlice.otherKey, label: "Other", value: value, share: share, isOther: true)
      ]
  }

  // MARK: Nesting

  /// Network regions around coin cells, only when that stays legible: asset
  /// grouping, full density, two to six regions each holding at least 8% of the
  /// value, and at most 14 coin cells in all.
  static func shouldNest(
    regions: [AtlasMapRegion], grouping: PortfolioGrouping, compact: Bool, nesting: AtlasMapNesting
  ) -> Bool {
    guard nesting == .automatic, grouping == .asset, !compact else { return false }
    guard (2...6).contains(regions.count) else { return false }
    guard regions.allSatisfy({ $0.share >= 0.08 }) else { return false }
    return regions.map(\.children.count).reduce(0, +) <= 14
  }

  static func plan(
    holdings: [TrackedAsset], grouping: PortfolioGrouping, compact: Bool,
    nesting: AtlasMapNesting = .automatic
  ) -> AtlasMapPlan {
    let flat = PortfolioAnalytics.breakdown(holdings, by: grouping)
    if grouping == .asset, nesting == .automatic, !compact {
      let nested = PortfolioAnalytics.breakdown(holdings, by: .network, then: .asset)
      let regions = nested.slices.filter { $0.valueUsd > 0 }.map { slice in
        AtlasMapRegion(
          key: slice.key, label: slice.label, value: slice.valueUsd, share: slice.share,
          children: slice.children.filter { $0.valueUsd > 0 }.map { child in
            AtlasMapSlice(
              key: child.key, label: child.label, value: child.valueUsd,
              share: nested.totalValueUsd > 0 ? child.valueUsd / nested.totalValueUsd : 0)
          })
      }
      if shouldNest(regions: regions, grouping: grouping, compact: compact, nesting: nesting) {
        return AtlasMapPlan(
          grouping: grouping, total: nested.totalValueUsd, slices: [], regions: regions,
          unpricedCount: nested.unpriced.count)
      }
    }
    return AtlasMapPlan(
      grouping: grouping, total: flat.totalValueUsd,
      slices: folding(
        flat.slices.map(AtlasMapSlice.init), minimumShare: minimumShare(compact: compact),
        maximumCount: maximumCells(compact: compact)),
      regions: [], unpricedCount: flat.unpriced.count)
  }

  // MARK: Geometry

  /// Outer boundary: the canvas less a hairline margin, with the theme's large
  /// corner radius (none for hard-edged themes), capped so it stays a map and
  /// not a pill.
  static func boundary(size: CGSize, cornerRadius: CGFloat) -> [CGPoint] {
    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
    guard rect.width > 8, rect.height > 8 else { return [] }
    return ConvexPolygon.roundedRectangle(
      rect, cornerRadius: min(cornerRadius, 0.2 * min(rect.width, rect.height)))
  }

  static func key(size: CGSize, compact: Bool, cornerRadius: CGFloat) -> AtlasMapKey {
    AtlasMapKey(
      width: size.width.rounded(), height: size.height.rounded(), compact: compact,
      cornerRadius: cornerRadius)
  }

  static func layout(plan: AtlasMapPlan, size: CGSize, cornerRadius: CGFloat) -> AtlasMapLayout {
    let outline = boundary(size: size, cornerRadius: cornerRadius)
    guard outline.count >= 3, !plan.isEmpty else {
      return AtlasMapLayout(boundary: outline, cells: [], regions: [], maximumError: 0)
    }
    var worst = 0.0
    var cells: [AtlasMapCell] = []
    var shapes: [AtlasMapRegionShape] = []

    func append(
      _ result: PowerDiagramResult, slices: [AtlasMapSlice], region: AtlasMapRegion?
    ) {
      worst = max(worst, result.maximumError)
      let byKey = Dictionary(uniqueKeysWithValues: slices.map { ($0.key, $0) })
      for cell in result.cells {
        guard let slice = byKey[cell.key] else { continue }
        let pole = ConvexPolygon.pole(cell.polygon)
        cells.append(
          AtlasMapCell(
            id: region.map { "\($0.key)>\(slice.key)" } ?? slice.key, key: slice.key,
            label: slice.label, value: slice.value, share: slice.share, isOther: slice.isOther,
            regionKey: region?.key, regionLabel: region?.label, polygon: cell.polygon,
            pole: pole.center, poleRadius: pole.radius, area: cell.area,
            targetArea: cell.targetArea))
      }
    }

    if plan.isNested {
      let top = PowerDiagramTreemap.layout(
        items: plan.regions.map { PowerDiagramItem(key: $0.key, value: $0.value) },
        boundary: outline)
      worst = max(worst, top.maximumError)
      for regionCell in top.cells {
        guard let region = plan.regions.first(where: { $0.key == regionCell.key }) else {
          continue
        }
        shapes.append(
          AtlasMapRegionShape(
            key: region.key, label: region.label, value: region.value, share: region.share,
            polygon: regionCell.polygon))
        let inner = ConvexPolygon.inset(regionCell.polygon, by: 3) ?? regionCell.polygon
        let result = PowerDiagramTreemap.layout(
          items: region.children.map { PowerDiagramItem(key: $0.key, value: $0.value) },
          boundary: inner)
        append(result, slices: region.children, region: region)
      }
    } else {
      let result = PowerDiagramTreemap.layout(
        items: plan.slices.map { PowerDiagramItem(key: $0.key, value: $0.value) },
        boundary: outline)
      append(result, slices: plan.slices, region: nil)
    }
    return AtlasMapLayout(boundary: outline, cells: cells, regions: shapes, maximumError: worst)
  }

  static func hitTest(_ point: CGPoint, layout: AtlasMapLayout) -> String? {
    for cell in layout.cells where ConvexPolygon.contains(cell.polygon, point) { return cell.id }
    return nil
  }

  // MARK: Selection

  /// What a click on `cell` selects; nil for the combined "Other" cell.
  static func selection(for cell: AtlasMapCell, grouping: PortfolioGrouping)
    -> PortfolioChartSelection?
  {
    guard !cell.isOther else { return nil }
    return grouping == .asset ? .coin(cell.key) : .slice(grouping: grouping, key: cell.key)
  }

  // MARK: Labels

  struct LabelPlan: Equatable {
    var lines: [String]
    var center: CGPoint
    var lineSizes: [CGSize]
  }

  /// The first of `variants` (richest first) whose text block fits inside
  /// `polygon`, with the point it should be centred on. `measure` gives the size
  /// of one line by its index in the variant, so the planner needs no fonts.
  static func planLabel(
    polygon: [CGPoint], variants: [[String]], margin: CGFloat = 2, avoiding: [CGRect] = [],
    measure: (_ text: String, _ lineIndex: Int) -> CGSize
  ) -> LabelPlan? {
    for lines in variants where !lines.isEmpty {
      let sizes = lines.enumerated().map { measure($0.element, $0.offset) }
      let width = sizes.map(\.width).max() ?? 0
      let height = sizes.map(\.height).reduce(0, +)
      guard width > 0, height > 0 else { continue }
      guard
        let center = ConvexPolygon.labelCenter(
          for: polygon, size: CGSize(width: width, height: height), margin: margin)
      else { continue }
      let rect = CGRect(
        x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
      if avoiding.contains(where: { $0.intersects(rect) }) { continue }
      return LabelPlan(lines: lines, center: center, lineSizes: sizes)
    }
    return nil
  }

  /// Where a `size` tag fits closest to the top-left corner of `polygon`, or nil
  /// when it does not fit anywhere. Scans rows from the top, left to right.
  static func cornerLabelCenter(polygon: [CGPoint], size: CGSize, margin: CGFloat = 4)
    -> CGPoint?
  {
    guard polygon.count >= 3, size.width > 0, size.height > 0 else { return nil }
    let box = ConvexPolygon.boundingBox(polygon)
    let step: CGFloat = 3
    var y = box.minY + size.height / 2 + margin
    while y <= box.maxY - size.height / 2 - margin {
      var x = box.minX + size.width / 2 + margin
      while x <= box.maxX - size.width / 2 - margin {
        let corners = [
          CGPoint(x: x - size.width / 2 - margin, y: y - size.height / 2 - margin),
          CGPoint(x: x + size.width / 2 + margin, y: y - size.height / 2 - margin),
          CGPoint(x: x - size.width / 2 - margin, y: y + size.height / 2 + margin),
          CGPoint(x: x + size.width / 2 + margin, y: y + size.height / 2 + margin),
        ]
        if corners.allSatisfy({ ConvexPolygon.contains(polygon, $0) }) {
          return CGPoint(x: x, y: y)
        }
        x += step
      }
      y += step
    }
    return nil
  }

  /// Label variants for a cell, richest first.
  static func labelVariants(
    cell: AtlasMapCell, compact: Bool, includesValue: Bool = true
  ) -> [[String]] {
    let share = HistoryChartFormat.percent(cell.share)
    var variants: [[String]] = []
    if !compact, includesValue {
      variants.append([cell.label, "\(HistoryChartFormat.usd(cell.value)) \u{00B7} \(share)"])
      variants.append([cell.label, "\(HistoryChartFormat.usdCompact(cell.value)) \u{00B7} \(share)"])
    }
    variants.append([cell.label, share])
    variants.append([cell.label])
    return variants
  }

  // MARK: Words

  static func summary(plan: AtlasMapPlan) -> String {
    let noun: String
    switch plan.grouping {
    case .asset: noun = "coin"
    case .network: noun = "network"
    case .source: noun = "wallet or exchange"
    case .state: noun = "state"
    case .kind: noun = "type"
    }
    let slices =
      plan.isNested
      ? plan.regions.flatMap(\.children).sorted { $0.value > $1.value } : plan.slices
    var text =
      "Atlas map of \(HistoryChartFormat.usd(plan.total)) by \(plan.grouping.displayName.lowercased()), "
      + "\(HistoryChartFormat.count(plan.cellCount, "area")) "
      + (plan.isNested ? "grouped into \(plan.regions.count) networks." : "of \(noun).")
    if let largest = slices.first(where: { !$0.isOther }) {
      text += " Largest: \(largest.label), \(HistoryChartFormat.percent(largest.share))."
    }
    return text
  }

  static func accessibilityLabel(for cell: AtlasMapCell) -> String {
    let place = cell.regionLabel.map { " on \($0)" } ?? ""
    return
      "\(cell.label)\(place), \(HistoryChartFormat.usd(cell.value)), \(HistoryChartFormat.percent(cell.share)) of the portfolio"
  }

  static func tooltipLines(for cell: AtlasMapCell) -> [String] {
    var lines = [
      cell.label,
      "\(HistoryChartFormat.usd(cell.value)) \u{00B7} \(HistoryChartFormat.percent(cell.share))",
    ]
    if let region = cell.regionLabel { lines.append("on \(region)") }
    return lines
  }
}
