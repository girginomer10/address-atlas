import CoreGraphics
import XCTest

@testable import AddressAtlasMac

/// The layout maths behind the part-C1 views: treemap, waffle, bubble packing,
/// ring angles and strip widths. Pure functions, so these run without a view.
final class ChartKitLayoutTests: XCTestCase {
  /// Value sets that matter: the design portfolio, equal values, one giant and
  /// many dust-sized values, a single value, and a spread of forty.
  private static let valueSets: [(name: String, values: [Double])] = [
    ("portfolio", [27_980.1, 13_120, 5_082, 2_109.36, 920.05]),
    ("equal", [10, 10, 10, 10, 10, 10, 10]),
    ("dominant", [1_000_000, 3, 2, 2, 1, 1, 0.5]),
    ("single", [42]),
    ("two", [3, 1]),
    ("forty", (1...40).map { 1_000 / Double($0) }),
    ("shuffled", [5, 90, 1, 30, 7, 60, 2]),
  ]

  private static let boundsList: [CGRect] = [
    CGRect(x: 0, y: 0, width: 640, height: 400),
    CGRect(x: 12, y: 7, width: 320, height: 200),
    CGRect(x: 0, y: 0, width: 200, height: 600),
    CGRect(x: 3, y: 5, width: 1_000, height: 90),
  ]

  // MARK: Treemap

  func testTreemapAreasAreProportionalAndInsideTheBounds() {
    for bounds in Self.boundsList {
      for set in Self.valueSets {
        let rects = ChartKitTreemap.layout(values: set.values, in: bounds)
        XCTAssertEqual(rects.count, set.values.count)
        let total = set.values.reduce(0, +)
        let boundsArea = Double(bounds.width * bounds.height)
        var areaSum = 0.0
        for (index, rect) in rects.enumerated() {
          let area = Double(rect.width * rect.height)
          areaSum += area
          let expected = set.values[index] / total * boundsArea
          XCTAssertEqual(
            area, expected, accuracy: max(1e-6, expected * 1e-6), "\(set.name) \(bounds) #\(index)")
          XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 1e-6)
          XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 1e-6)
          XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 1e-6)
          XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 1e-6)
        }
        XCTAssertEqual(areaSum, boundsArea, accuracy: boundsArea * 1e-9, "\(set.name) tiles")
      }
    }
  }

  func testTreemapRectanglesDoNotOverlap() {
    for set in Self.valueSets {
      let rects = ChartKitTreemap.layout(values: set.values, in: Self.boundsList[0])
      for first in 0..<rects.count {
        for second in (first + 1)..<rects.count {
          let overlap = rects[first].intersection(rects[second])
          let area = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
          XCTAssertLessThan(area, 1e-6, "\(set.name) \(first) and \(second)")
        }
      }
    }
  }

  func testTreemapKeepsTheOrderOfTheInputAndIsDeterministic() {
    let values: [Double] = [5, 90, 1, 30, 7]
    let bounds = Self.boundsList[0]
    let first = ChartKitTreemap.layout(values: values, in: bounds)
    XCTAssertEqual(first, ChartKitTreemap.layout(values: values, in: bounds))
    // The largest value gets the largest rectangle wherever it sits in the list.
    let areas = first.map { $0.width * $0.height }
    XCTAssertEqual(areas.firstIndex(of: areas.max()!), 1)
    // Largest first and shuffled give the same rectangle for the same value.
    let sorted = ChartKitTreemap.layout(values: values.sorted(by: >), in: bounds)
    XCTAssertEqual(sorted[0], first[1])
  }

  func testTreemapGivesEmptyRectanglesToValuesWithoutArea() {
    let rects = ChartKitTreemap.layout(
      values: [10, 0, -3, .nan, .infinity, 10], in: CGRect(x: 0, y: 0, width: 100, height: 100))
    XCTAssertEqual(rects[1].size, .zero)
    XCTAssertEqual(rects[2].size, .zero)
    XCTAssertEqual(rects[3].size, .zero)
    XCTAssertEqual(rects[4].size, .zero)
    XCTAssertEqual(Double(rects[0].width * rects[0].height), 5_000, accuracy: 1e-6)
    XCTAssertEqual(Double(rects[5].width * rects[5].height), 5_000, accuracy: 1e-6)
    XCTAssertEqual(
      ChartKitTreemap.layout(values: [1, 2], in: .zero).map(\.size), [.zero, .zero])
    XCTAssertEqual(
      ChartKitTreemap.layout(values: [0, 0], in: CGRect(x: 0, y: 0, width: 9, height: 9)).map(\.size),
      [.zero, .zero])
  }

  func testTreemapBlocksStayReasonablyShapedForTheDesignPortfolio() {
    // Squarified: no block of the design portfolio is a sliver.
    let rects = ChartKitTreemap.layout(
      values: Self.valueSets[0].values, in: CGRect(x: 0, y: 0, width: 640, height: 400))
    for rect in rects {
      let ratio = max(rect.width / rect.height, rect.height / rect.width)
      XCTAssertLessThan(ratio, 4.5, "\(rect)")
    }
  }

  // MARK: Waffle

  func testWaffleAlwaysAllocatesExactlyOneHundredCells() {
    var generator = SplitMix(seed: 7)
    var sets = Self.valueSets.map(\.values)
    for _ in 0..<200 {
      let count = Int(generator.next() % 14) + 1
      sets.append((0..<count).map { _ in Double(generator.next() % 10_000) / 7 })
    }
    for shares in sets {
      let counts = ChartKitWaffle.allocate(shares: shares)
      if shares.contains(where: { $0 > 0 }) {
        XCTAssertEqual(counts.reduce(0, +), 100, "\(shares)")
      }
      XCTAssertEqual(ChartKitWaffle.owners(counts: counts).count, counts.reduce(0, +))
      for (index, share) in shares.enumerated() where share <= 0 {
        XCTAssertEqual(counts[index], 0)
      }
    }
  }

  func testWaffleUsesLargestRemainders() {
    // The design portfolio: quotas 56.86, 26.66, 10.33, 4.29, 1.87.
    XCTAssertEqual(
      ChartKitWaffle.allocate(shares: Self.valueSets[0].values), [57, 27, 10, 4, 2])
    // Equal thirds: the extra cell goes to the earliest.
    XCTAssertEqual(ChartKitWaffle.allocate(shares: [1, 1, 1]), [34, 33, 33])
    // A slice below half a percent can still get a cell when its remainder wins.
    XCTAssertEqual(ChartKitWaffle.allocate(shares: [99.6, 0.4]).reduce(0, +), 100)
    XCTAssertEqual(ChartKitWaffle.allocate(shares: [1]), [100])
    XCTAssertEqual(ChartKitWaffle.allocate(shares: [0, 0, 0]), [0, 0, 0])
    XCTAssertEqual(ChartKitWaffle.allocate(shares: []), [])
    XCTAssertEqual(ChartKitWaffle.allocate(shares: [3, .nan, -1, 1]), [75, 0, 0, 25])
  }

  func testWaffleOwnersFillInReadingOrder() {
    XCTAssertEqual(ChartKitWaffle.owners(counts: [2, 0, 3]), [0, 0, 2, 2, 2])
  }

  // MARK: Bubbles

  func testBubblePackingHasNoOverlapsAndStaysInBounds() {
    var generator = SplitMix(seed: 99)
    var sets = Self.valueSets.map(\.values)
    for _ in 0..<40 {
      let count = Int(generator.next() % 18) + 1
      sets.append((0..<count).map { _ in Double(generator.next() % 100_000) + 1 })
    }
    for bounds in Self.boundsList {
      for gap in [CGFloat(0), 3.5, 8] {
        for values in sets {
          let circles = ChartKitBubblePacking.pack(values: values, in: bounds, gap: gap)
          XCTAssertEqual(circles.count, values.count)
          for (index, circle) in circles.enumerated() {
            XCTAssertGreaterThanOrEqual(circle.center.x - circle.radius, bounds.minX - 1e-6)
            XCTAssertLessThanOrEqual(circle.center.x + circle.radius, bounds.maxX + 1e-6)
            XCTAssertGreaterThanOrEqual(circle.center.y - circle.radius, bounds.minY - 1e-6)
            XCTAssertLessThanOrEqual(circle.center.y + circle.radius, bounds.maxY + 1e-6)
            for other in (index + 1)..<max(index + 1, circles.count) {
              let distance = hypot(
                circle.center.x - circles[other].center.x, circle.center.y - circles[other].center.y)
              // Circles keep at least (about) the requested gap between them.
              XCTAssertGreaterThanOrEqual(
                distance, circle.radius + circles[other].radius + gap * 0.9 - 1e-6,
                "\(values.count) values, gap \(gap), \(bounds)")
            }
          }
        }
      }
    }
  }

  func testBubbleAreaIsProportionalToValue() {
    let values: [Double] = [27_980.1, 13_120, 5_082, 2_109.36, 920.05]
    let circles = ChartKitBubblePacking.pack(
      values: values, in: CGRect(x: 0, y: 0, width: 640, height: 400), gap: 4)
    for index in 1..<values.count {
      let areaRatio = Double(circles[index].radius * circles[index].radius)
        / Double(circles[0].radius * circles[0].radius)
      XCTAssertEqual(areaRatio, values[index] / values[0], accuracy: 1e-6)
    }
  }

  func testBubblePackingIsDeterministicAndKeepsInputOrder() {
    let values: [Double] = [3, 90, 20, 7, 41]
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
    let first = ChartKitBubblePacking.pack(values: values, in: bounds, gap: 3)
    XCTAssertEqual(first, ChartKitBubblePacking.pack(values: values, in: bounds, gap: 3))
    // The largest value gets the largest circle wherever it is listed.
    XCTAssertEqual(first.map(\.radius).firstIndex(of: first.map(\.radius).max()!), 1)
  }

  func testBubblePackingGivesNothingToValuesWithoutArea() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
    let circles = ChartKitBubblePacking.pack(values: [5, 0, -1, .nan], in: bounds)
    XCTAssertGreaterThan(circles[0].radius, 0)
    XCTAssertEqual(circles[1].radius, 0)
    XCTAssertEqual(circles[2].radius, 0)
    XCTAssertEqual(circles[3].radius, 0)
    XCTAssertEqual(ChartKitBubblePacking.pack(values: [], in: bounds), [])
    XCTAssertEqual(ChartKitBubblePacking.pack(values: [1, 2], in: .zero).map(\.radius), [0, 0])
  }

  func testASingleBubbleFillsTheShortSideAndTheClusterFillsTheArea() {
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 300)
    let single = ChartKitBubblePacking.pack(values: [9], in: bounds)
    XCTAssertEqual(single[0].radius, 150, accuracy: 1e-6)
    XCTAssertEqual(single[0].center.x, 300, accuracy: 1e-6)
    // The design portfolio uses a good part of a wide area.
    let circles = ChartKitBubblePacking.pack(
      values: Self.valueSets[0].values, in: bounds, gap: 4)
    let used = circles.reduce(0.0) { $0 + Double.pi * Double($1.radius * $1.radius) }
    XCTAssertGreaterThan(used / Double(bounds.width * bounds.height), 0.3)
  }

  // MARK: Arcs

  func testRingAnglesSumToAFullTurn() {
    for set in Self.valueSets {
      let arcs = ChartKitSunburst.tile(values: set.values)
      XCTAssertEqual(arcs.map(\.span).reduce(0, +), 2 * .pi, accuracy: 1e-12, set.name)
      XCTAssertEqual(arcs.first?.start, 0)
      XCTAssertEqual(arcs.last?.end ?? 0, 2 * .pi, accuracy: 1e-12)
      for (index, arc) in arcs.enumerated() {
        XCTAssertEqual(arc.span, set.values[index] / set.values.reduce(0, +) * 2 * .pi, accuracy: 1e-9)
        if index > 0 { XCTAssertEqual(arc.start, arcs[index - 1].end, accuracy: 1e-12) }
      }
    }
  }

  func testSunburstOuterArcsTileTheirParents() {
    let parents: [Double] = [27_980, 13_120, 5_082, 2_109, 920]
    let children: [[Double]] = [[24_584, 3_396], [8_320, 3_200, 1_600], [3_432, 1_650], [1_904, 169, 29, 8], []]
    let rings = ChartKitSunburst.rings(parents: parents, children: children)
    XCTAssertEqual(rings.inner.map(\.span).reduce(0, +), 2 * .pi, accuracy: 1e-12)
    XCTAssertEqual(rings.outer.flatMap { $0 }.map(\.span).reduce(0, +) , 2 * .pi - rings.inner[4].span, accuracy: 1e-12)
    for (index, parent) in rings.inner.enumerated() {
      let arcs = rings.outer[index]
      if arcs.isEmpty { continue }
      XCTAssertEqual(arcs.first?.start ?? -1, parent.start, accuracy: 1e-12)
      XCTAssertEqual(arcs.last?.end ?? -1, parent.end, accuracy: 1e-12)
      XCTAssertEqual(arcs.map(\.span).reduce(0, +), parent.span, accuracy: 1e-12)
    }
  }

  func testSunburstOuterRingCoversTheFullTurnWhenEveryParentHasParts() {
    let rings = ChartKitSunburst.rings(
      parents: [60, 40], children: [[30, 30], [10, 10, 20]])
    XCTAssertEqual(rings.outer.flatMap { $0 }.map(\.span).reduce(0, +), 2 * .pi, accuracy: 1e-12)
  }

  func testArcInsetLeavesAGapAndKeepsAFullCircleWhole() {
    let arc = ChartKitArc(start: 1, end: 2)
    let inset = ChartKitSunburst.inset(arc, gapAngle: 0.1)
    XCTAssertEqual(inset.start, 1.05, accuracy: 1e-12)
    XCTAssertEqual(inset.end, 1.95, accuracy: 1e-12)
    let full = ChartKitArc(start: 0, end: 2 * .pi)
    XCTAssertEqual(ChartKitSunburst.inset(full, gapAngle: 0.1), full)
    // A sliver narrower than the gap shrinks by at most a quarter per side.
    let sliver = ChartKitSunburst.inset(ChartKitArc(start: 0, end: 0.04), gapAngle: 0.1)
    XCTAssertGreaterThan(sliver.span, 0)
    XCTAssertEqual(sliver.span, 0.02, accuracy: 1e-12)
  }

  // MARK: Strip

  func testStripWidthsAndGapsFillTheBarExactly() {
    for set in Self.valueSets {
      let widths = ChartKitStrip.widths(shares: set.values, width: 640, gap: 3)
      let gaps = 3 * CGFloat(widths.filter { $0 > 0 }.count - 1)
      XCTAssertEqual(widths.reduce(0, +) + gaps, 640, accuracy: 1e-6, set.name)
    }
    XCTAssertEqual(ChartKitStrip.widths(shares: [1, 0, 1], width: 103, gap: 3), [50, 0, 50])
    XCTAssertEqual(ChartKitStrip.widths(shares: [0, 0], width: 100, gap: 3), [0, 0])
  }

  func testLabelBudgetIsGenerousButFinite() {
    XCTAssertTrue(ChartKitLabelBudget.fits(characters: 3, fontSize: 11, in: 40))
    XCTAssertFalse(ChartKitLabelBudget.fits(characters: 12, fontSize: 11, in: 40))
    XCTAssertEqual(ChartKitLabelBudget.width(characters: -2, fontSize: 11), 0)
  }
}

/// A small seeded generator, so the "random" cases are the same on every run.
struct SplitMix {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
