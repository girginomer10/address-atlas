import CoreGraphics
import Foundation
import XCTest

@testable import AddressAtlasMac

final class PowerDiagramTreemapTests: XCTestCase {
  private let bounds = CGRect(x: 0, y: 0, width: 640, height: 400)

  private func boundary(radius: CGFloat = 28) -> [CGPoint] {
    ConvexPolygon.roundedRectangle(bounds, cornerRadius: radius)
  }

  /// Power-law-ish values, none under 1% of the total.
  private func items(count: Int) -> [PowerDiagramItem] {
    (0..<count).map { index in
      PowerDiagramItem(key: "coin-\(index)", value: 1000 / pow(Double(index + 1), 0.9) + 40)
    }
  }

  func testThirtySlicesAreWithinTolerance() {
    let result = PowerDiagramTreemap.layout(items: items(count: 30), boundary: boundary())
    XCTAssertEqual(result.cells.count, 30)
    XCTAssertLessThanOrEqual(result.maximumError, 0.03, "max relative area error")
    for cell in result.cells {
      XCTAssertEqual(cell.area, cell.targetArea, accuracy: cell.targetArea * 0.03, cell.key)
    }
  }

  func testCellsTileTheBoundaryAndStayInsideIt() {
    let outline = boundary()
    let result = PowerDiagramTreemap.layout(items: items(count: 12), boundary: outline)
    let total = result.cells.map(\.area).reduce(0, +)
    XCTAssertEqual(total, ConvexPolygon.area(outline), accuracy: 1.0)
    for cell in result.cells {
      XCTAssertGreaterThanOrEqual(cell.polygon.count, 3, cell.key)
      for point in cell.polygon {
        XCTAssertTrue(ConvexPolygon.contains(outline, point), "\(cell.key) \(point)")
      }
    }
  }

  func testLayoutIsDeterministic() {
    let first = PowerDiagramTreemap.layout(items: items(count: 20), boundary: boundary())
    let second = PowerDiagramTreemap.layout(items: items(count: 20), boundary: boundary())
    XCTAssertEqual(first, second)
  }

  func testSeedChangesTheArrangementButNotTheAreas() {
    var config = PowerDiagramConfig()
    config.seed = 99
    let other = PowerDiagramTreemap.layout(
      items: items(count: 10), boundary: boundary(), config: config)
    let base = PowerDiagramTreemap.layout(items: items(count: 10), boundary: boundary())
    XCTAssertNotEqual(base.cells.map(\.site), other.cells.map(\.site))
    XCTAssertLessThanOrEqual(other.maximumError, 0.03)
  }

  func testSingleItemFillsTheBoundary() {
    let outline = boundary()
    let result = PowerDiagramTreemap.layout(
      items: [PowerDiagramItem(key: "BTC", value: 5)], boundary: outline)
    XCTAssertEqual(result.cells.count, 1)
    XCTAssertEqual(result.cells[0].area, ConvexPolygon.area(outline), accuracy: 0.001)
  }

  func testNonPositiveValuesAreIgnored() {
    let result = PowerDiagramTreemap.layout(
      items: [
        PowerDiagramItem(key: "A", value: 3), PowerDiagramItem(key: "B", value: 0),
        PowerDiagramItem(key: "C", value: -4), PowerDiagramItem(key: "D", value: .nan),
        PowerDiagramItem(key: "E", value: 1),
      ], boundary: boundary())
    XCTAssertEqual(result.cells.map(\.key), ["A", "E"])
  }

  /// Different sizes, skews, and seeds: every cell stays non-empty and close to
  /// its share. A seed that puts two sites on top of each other used to leave
  /// one cell swallowed whole by its neighbour.
  func testManyShapesConvergeAndNoCellVanishes() {
    for count in [4, 9, 16, 30] {
      for skew in [0.7, 1.2] {
        let raw = (0..<count).map { 1 / pow(Double($0 + 1), skew) }
        let total = raw.reduce(0, +)
        guard (raw.last ?? 0) / total >= 0.008 else { continue }
        let items = raw.enumerated().map {
          PowerDiagramItem(key: "item-\($0.offset)", value: $0.element)
        }
        for seed in 0..<6 {
          var config = PowerDiagramConfig()
          config.seed = UInt64(seed)
          let result = PowerDiagramTreemap.layout(
            items: items, boundary: boundary(), config: config)
          XCTAssertEqual(result.cells.count, count)
          XCTAssertLessThanOrEqual(
            result.maximumError, 0.05, "n \(count) skew \(skew) seed \(seed)")
          for cell in result.cells {
            XCTAssertGreaterThan(cell.area, 0, "empty \(cell.key): n \(count) seed \(seed)")
          }
        }
      }
    }
  }

  func testSmallCountsConverge() {
    for count in 2...6 {
      let result = PowerDiagramTreemap.layout(items: items(count: count), boundary: boundary())
      XCTAssertLessThanOrEqual(result.maximumError, 0.03, "\(count) items")
    }
  }

  func testCompactBoundaryWithEightSlices() {
    let small = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 320, height: 200), cornerRadius: 16)
    let result = PowerDiagramTreemap.layout(items: items(count: 8), boundary: small)
    XCTAssertLessThanOrEqual(result.maximumError, 0.03)
  }

  func testThirtySlicesLayOutQuickly() {
    let input = items(count: 30)
    let outline = boundary()
    let start = Date()
    let result = PowerDiagramTreemap.layout(items: input, boundary: outline)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(result.cells.count, 30)
    // The budget is 50 ms in a release build. Debug builds are an order of
    // magnitude slower, so this only guards against an accidental blow-up.
    // Thread Sanitizer slows a debug build further (about 2 s on CI), so the
    // timing check is skipped there; the cell count above still runs.
    if !TestSanitizer.isThreadSanitizerActive {
      #if DEBUG
        XCTAssertLessThan(elapsed, 1.5)
      #else
        XCTAssertLessThan(elapsed, 0.05)
      #endif
    }
    print(
      "power diagram, 30 items: \(Int(elapsed * 1000)) ms, \(result.evaluations) evaluations, error \(result.maximumError)"
    )
  }

  // MARK: Polygon helpers

  func testRoundedRectangleIsConvexAndHasTheRectangleArea() {
    let polygon = ConvexPolygon.roundedRectangle(bounds, cornerRadius: 0)
    XCTAssertEqual(ConvexPolygon.area(polygon), 640 * 400, accuracy: 0.001)
    let rounded = ConvexPolygon.roundedRectangle(bounds, cornerRadius: 40)
    XCTAssertLessThan(ConvexPolygon.area(rounded), 640 * 400)
    // The polygon approximates each arc from the inside, so it is a little under
    // the exact rounded rectangle.
    let exact = 640 * 400 - (4 - Double.pi) * 40 * 40
    XCTAssertEqual(ConvexPolygon.area(rounded), exact, accuracy: 120)
    XCTAssertTrue(ConvexPolygon.contains(rounded, CGPoint(x: 320, y: 200)))
    XCTAssertFalse(ConvexPolygon.contains(rounded, CGPoint(x: 1, y: 1)))
  }

  func testPoleOfInaccessibilityIsTheInscribedCircleCentre() {
    let rectangle = ConvexPolygon.roundedRectangle(
      CGRect(x: 10, y: 20, width: 100, height: 40), cornerRadius: 0)
    let pole = ConvexPolygon.pole(rectangle)
    XCTAssertEqual(pole.radius, 20, accuracy: 0.1)
    XCTAssertEqual(pole.center.y, 40, accuracy: 0.2)
    XCTAssertGreaterThan(pole.center.x, 29.8)
    XCTAssertLessThan(pole.center.x, 90.2)
  }

  func testLabelCenterFitsOnlyWhenTheLabelFits() {
    let rectangle = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 100, height: 40), cornerRadius: 0)
    let fits = ConvexPolygon.labelCenter(for: rectangle, size: CGSize(width: 80, height: 20))
    XCTAssertNotNil(fits)
    if let fits {
      XCTAssertEqual(fits.y, 20, accuracy: 0.5)
    }
    XCTAssertNil(ConvexPolygon.labelCenter(for: rectangle, size: CGSize(width: 120, height: 20)))
    XCTAssertNil(ConvexPolygon.labelCenter(for: rectangle, size: CGSize(width: 80, height: 50)))
  }

  func testInsetShrinksAndCanDisappear() {
    let rectangle = ConvexPolygon.roundedRectangle(
      CGRect(x: 0, y: 0, width: 100, height: 40), cornerRadius: 0)
    let inset = ConvexPolygon.inset(rectangle, by: 5)
    XCTAssertNotNil(inset)
    XCTAssertEqual(ConvexPolygon.area(inset ?? []), 90 * 30, accuracy: 0.01)
    XCTAssertNil(ConvexPolygon.inset(rectangle, by: 25))
  }
}
