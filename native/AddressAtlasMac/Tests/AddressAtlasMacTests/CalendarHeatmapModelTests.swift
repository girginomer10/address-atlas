import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

/// Calendar bucketing: which day a scan belongs to in which time zone, how days
/// fall into week columns, and that days without a scan stay empty.
final class CalendarHeatmapModelTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC") ?? .current
  private let paris = TimeZone(identifier: "Europe/Paris") ?? .current
  private let auckland = TimeZone(identifier: "Pacific/Auckland") ?? .current
  private let honolulu = TimeZone(identifier: "Pacific/Honolulu") ?? .current

  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  private func model(
    runs: [ScanRunRecord],
    timeZone: TimeZone? = nil,
    firstWeekday: Int = 1,
    minimumWeeks: Int = 8,
    maximumWeeks: Int = 26
  ) -> CalendarHeatmapModel? {
    let points = PortfolioAnalytics.dailySeries(runs, timeZone: timeZone ?? utc)
    return CalendarHeatmapModel.make(
      points: points, runs: runs, context: nil, firstWeekday: firstWeekday,
      minimumWeeks: minimumWeeks, maximumWeeks: maximumWeeks)
  }

  private func isoRun(_ text: String, total: Double = 1_000) -> ScanRunRecord {
    let date = ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    let holding = TrackedAsset(
      id: "btc-\(text)", address: ChartFixture.bitcoinAddress, chainId: "bitcoin",
      chainName: "Bitcoin", family: .bitcoin, symbol: "BTC", name: "Bitcoin", amount: 1,
      priceUsd: total, valueUsd: total, pricingStatus: .priced, source: .native,
      walletLabel: "Cold")
    return ScanRunRecord(generatedAt: date, totalUsd: total, inputCount: 1, holdings: [holding])
  }

  // MARK: Civil day arithmetic

  func testDayNumbersRoundTripAcrossCenturiesAndLeapDays() {
    for number in stride(from: -800, through: 40_000, by: 13) {
      let day = CivilDay.day(number: number)
      XCTAssertEqual(CivilDay.number(day), number, "\(day.id)")
    }
    XCTAssertEqual(CivilDay.number(CivilDate(year: 1970, month: 1, day: 1)), 0)
    XCTAssertEqual(CivilDay.day(number: 0), CivilDate(year: 1970, month: 1, day: 1))
    // 2024 is a leap year, 2100 is not.
    XCTAssertEqual(
      CivilDay.number(CivilDate(year: 2024, month: 3, day: 1))
        - CivilDay.number(CivilDate(year: 2024, month: 2, day: 28)), 2)
    XCTAssertEqual(
      CivilDay.number(CivilDate(year: 2100, month: 3, day: 1))
        - CivilDay.number(CivilDate(year: 2100, month: 2, day: 28)), 1)
    XCTAssertEqual(CivilDate(year: 2026, month: 3, day: 9).id, "2026-03-09")
  }

  func testWeekdaysOfKnownDates() {
    // Sunday is 0.
    let cases: [(CivilDate, Int)] = [
      (CivilDate(year: 1970, month: 1, day: 1), 4),  // Thursday
      (CivilDate(year: 2000, month: 2, day: 29), 2),  // Tuesday
      (CivilDate(year: 2026, month: 11, day: 4), 3),  // Wednesday
      (CivilDate(year: 2026, month: 9, day: 24), 4),  // Thursday
      (CivilDate(year: 1969, month: 12, day: 31), 3),  // Wednesday
    ]
    for (day, weekday) in cases {
      XCTAssertEqual(CivilDay.weekday(number: CivilDay.number(day)), weekday, day.id)
    }
  }

  // MARK: Thresholds

  func testFewerThanSevenScanDaysGivesNoCalendar() {
    let runs = (0..<6).map { ChartFixture.run(day: $0) }
    XCTAssertNil(model(runs: runs))
    XCTAssertEqual(CalendarHeatmapModel.minimumScanDays, 7)
    XCTAssertNotNil(model(runs: (0..<7).map { ChartFixture.run(day: $0) }))
    // Several scans on one day are one day.
    let sameDay = (0..<10).map { ChartFixture.run(day: 3, hour: $0) }
    XCTAssertNil(model(runs: sameDay))
  }

  // MARK: Grid

  func testGridPlacesDaysByWeekdayAndWeek() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs(), firstWeekday: 1))
    // 24 Sep to 4 Nov spans seven week columns; the minimum is eight.
    XCTAssertEqual(model.weeks, 8)
    let last = try XCTUnwrap(model.cells.last)
    XCTAssertEqual(last.day, CivilDate(year: 2026, month: 11, day: 4))
    XCTAssertEqual(last.column, model.weeks - 1)
    XCTAssertEqual(last.row, 3, "a Wednesday, with Sunday first")
    var positions = Set<String>()
    for cell in model.cells {
      XCTAssertTrue(positions.insert("\(cell.column),\(cell.row)").inserted, "duplicate cell")
      XCTAssertTrue((0..<7).contains(cell.row))
      XCTAssertTrue((0..<model.weeks).contains(cell.column))
    }
    // Days are consecutive: each cell is the day after the one before it.
    for (before, after) in zip(model.cells, model.cells.dropFirst()) {
      XCTAssertEqual(CivilDay.number(after.day) - CivilDay.number(before.day), 1)
    }
    XCTAssertEqual(model.cells.first?.column, 0)
    XCTAssertEqual(model.cells.first?.row, 0, "the grid starts on a week's first day")
  }

  func testMondayFirstMovesEveryRow() throws {
    let sunday = try XCTUnwrap(model(runs: ChartFixture.runs(), firstWeekday: 1))
    let monday = try XCTUnwrap(model(runs: ChartFixture.runs(), firstWeekday: 2))
    XCTAssertEqual(monday.cells.last?.row, 2, "Wednesday is the third day of a Monday week")
    XCTAssertEqual(monday.row(ofWeekday: 1), 0)
    XCTAssertEqual(monday.row(ofWeekday: 0), 6)
    XCTAssertEqual(monday.weekday(ofRow: 0), 1)
    XCTAssertEqual(sunday.weekday(ofRow: 0), 0)
    XCTAssertEqual(monday.firstWeekday, 2)
    for model in [sunday, monday] {
      for row in 0..<7 { XCTAssertEqual(model.row(ofWeekday: model.weekday(ofRow: row)), row) }
    }
  }

  func testDaysWithoutAScanAreEmptyNotZero() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    for skipped in ChartFixture.skippedDays {
      let date = ChartFixture.scanDate(day: skipped)
      let id = Self.id(of: date)
      let cell = try XCTUnwrap(model.cell(id: id), id)
      XCTAssertNil(cell.entry, "day \(skipped) has no scan")
    }
    XCTAssertEqual(model.scanCells.count, model.scanDayCount)
    XCTAssertEqual(model.scanDayCount, 42 - ChartFixture.skippedDays.count)
    // The empty cells before the first scan fill out the first week.
    XCTAssertTrue(model.cells.prefix(3).allSatisfy { $0.entry == nil })
  }

  func testTheWindowShowsTheLatestWeeksOnly() throws {
    let limited = try XCTUnwrap(
      model(runs: ChartFixture.runs(), minimumWeeks: 3, maximumWeeks: 4))
    XCTAssertEqual(limited.weeks, 4)
    XCTAssertEqual(limited.cells.last?.day, CivilDate(year: 2026, month: 11, day: 4))
    XCTAssertEqual(limited.cells.count, 3 * 7 + 4, "three full weeks and the latest, partial one")
    XCTAssertLessThan(limited.scanCells.count, limited.scanDayCount)
    // Month labels sit over the first row of the column where a month starts.
    XCTAssertFalse(limited.months.isEmpty)
    XCTAssertEqual(limited.months.map(\.column), limited.months.map(\.column).sorted())
  }

  func testMonthLabelsNameEachMonthOnce() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    XCTAssertEqual(model.months.map(\.month), [9, 10, 11])
    XCTAssertEqual(model.months.first?.column, 0)
  }

  // MARK: Colour and source changes

  func testASourceChangeIsHatchedNotColoured() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    let differing = model.scanCells.filter { $0.entry?.sourcesDiffer == true }
    XCTAssertEqual(differing.count, 1, "only the day the wallet was added")
    let cell = try XCTUnwrap(differing.first)
    XCTAssertEqual(cell.day, CivilDate(year: 2026, month: 10, day: 14))
    let entry = try XCTUnwrap(cell.entry)
    XCTAssertNil(entry.marketChange)
    XCTAssertEqual(model.intensity(of: entry), 0)
    XCTAssertNotNil(entry.point.changeUsd, "the change is still shown as a fact")
    let lines = CalendarHeatmapModel.lines(for: cell, timeZone: utc)
    XCTAssertTrue(lines.contains { $0.contains("not a market move") })
  }

  func testIntensityScalesWithTheChangeAndStopsAtOne() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    XCTAssertGreaterThanOrEqual(model.colorScale, 0.005)
    let intensities = model.scanCells.compactMap { $0.entry }.map { model.intensity(of: $0) }
    XCTAssertTrue(intensities.allSatisfy { (0...1).contains($0) })
    XCTAssertTrue(intensities.contains { $0 > 0.5 })
    XCTAssertTrue(intensities.contains(0), "the first scan has nothing to compare with")
  }

  func testFirstScanHasNoChange() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    let first = try XCTUnwrap(model.scanCells.first)
    XCTAssertNil(first.entry?.point.changeUsd)
    XCTAssertEqual(
      CalendarHeatmapModel.lines(for: first, timeZone: utc)[2], "First scan")
  }

  func testChangeLineNamesThePreviousScannedDay() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    // Day 26 follows the skipped days 24 and 25: the change is "since" day 23.
    let cell = try XCTUnwrap(model.cell(id: Self.id(of: ChartFixture.scanDate(day: 26))))
    let line = CalendarHeatmapModel.changeLine(try XCTUnwrap(cell.entry), timeZone: utc)
    XCTAssertTrue(line.hasSuffix("since Oct 17"), line)
    let empty = try XCTUnwrap(model.cell(id: Self.id(of: ChartFixture.scanDate(day: 25))))
    XCTAssertEqual(CalendarHeatmapModel.lines(for: empty, timeZone: utc)[1], "No scan")
  }

  func testBestAndWorstDayIgnoreSourceChangesAndTheFirstScan() throws {
    let model = try XCTUnwrap(model(runs: ChartFixture.runs()))
    let best = try XCTUnwrap(model.bestDay)
    let worst = try XCTUnwrap(model.worstDay)
    XCTAssertGreaterThan(best.entry?.marketChange ?? 0, 0)
    XCTAssertLessThan(worst.entry?.marketChange ?? 0, 0)
    for cell in model.scanCells {
      guard let change = cell.entry?.marketChange else { continue }
      XCTAssertLessThanOrEqual(change, best.entry?.marketChange ?? 0)
      XCTAssertGreaterThanOrEqual(change, worst.entry?.marketChange ?? 0)
    }
    XCTAssertTrue(model.summary(timeZone: utc).contains("Best day"))
  }

  // MARK: Time zones and daylight saving

  func testAScanBelongsToTheDayInTheTimeZoneThatIsAsked() throws {
    // 23:30 UTC on 3 Nov is 00:30 on 4 Nov in Paris and 12:30 on 4 Nov in
    // Auckland, but still 13:30 on 3 Nov in Honolulu.
    var runs = (0..<7).map { ChartFixture.run(day: $0) }
    runs.append(isoRun("2026-11-03T23:30:00Z"))
    let cases: [(TimeZone, CivilDate)] = [
      (utc, CivilDate(year: 2026, month: 11, day: 3)),
      (paris, CivilDate(year: 2026, month: 11, day: 4)),
      (auckland, CivilDate(year: 2026, month: 11, day: 4)),
      (honolulu, CivilDate(year: 2026, month: 11, day: 3)),
    ]
    for (zone, expected) in cases {
      let model = try XCTUnwrap(model(runs: runs, timeZone: zone), zone.identifier)
      XCTAssertEqual(model.latestDay, expected, zone.identifier)
    }
  }

  func testTheShortAndLongDaysOfDaylightSavingAreOneDayEach() throws {
    // Paris moves clocks on 29 March (a 23-hour day) and 25 October (25 hours).
    for (start, label) in [("2026-03-25", "spring"), ("2026-10-21", "autumn")] {
      var runs: [ScanRunRecord] = []
      let first = ISO8601DateFormatter().date(from: start + "T12:00:00Z") ?? Date()
      for offset in 0..<10 {
        // Noon UTC is 13:00 or 14:00 in Paris: always inside the same day.
        var run = isoRun("2026-01-01T00:00:00Z", total: 1_000 + Double(offset))
        run.generatedAt = first.addingTimeInterval(Double(offset) * 86_400)
        runs.append(run)
      }
      let model = try XCTUnwrap(model(runs: runs, timeZone: paris), label)
      XCTAssertEqual(model.scanDayCount, 10, label)
      let scanned = model.scanCells
      XCTAssertEqual(scanned.count, 10, label)
      for (before, after) in zip(scanned, scanned.dropFirst()) {
        XCTAssertEqual(
          CivilDay.number(after.day) - CivilDay.number(before.day), 1,
          "\(label): \(before.day.id) to \(after.day.id)")
      }
    }
  }

  func testTwoScansEitherSideOfTheSpringForwardShareADayInParis() throws {
    // 00:30 and 23:30 local time on 29 March 2026, 22 hours apart.
    let early = isoRun("2026-03-28T23:30:00Z", total: 900)
    let late = isoRun("2026-03-29T21:30:00Z", total: 950)
    let points = PortfolioAnalytics.dailySeries([early, late], timeZone: paris)
    XCTAssertEqual(points.count, 1)
    XCTAssertEqual(points.first?.runID, late.id, "the day's last scan stands for it")
    XCTAssertEqual(PortfolioAnalytics.dailySeries([early, late], timeZone: utc).count, 2)
  }

  func testTwoScansEitherSideOfTheFallBackShareADayInParis() throws {
    // 00:30 and 23:30 local time on 25 October 2026, 25 hours apart.
    let early = isoRun("2026-10-24T22:30:00Z", total: 900)
    let late = isoRun("2026-10-25T22:30:00Z", total: 950)
    let points = PortfolioAnalytics.dailySeries([early, late], timeZone: paris)
    XCTAssertEqual(points.count, 1)
    XCTAssertEqual(points.first?.runID, late.id)
  }

  func testNoonOfADayStaysInThatDay() {
    for (zone, day) in [
      (paris, CivilDate(year: 2026, month: 3, day: 29)),
      (paris, CivilDate(year: 2026, month: 10, day: 25)),
      (auckland, CivilDate(year: 2026, month: 9, day: 27)),
      (honolulu, CivilDate(year: 2026, month: 1, day: 1)),
    ] {
      let noon = CalendarHeatmapModel.noon(day, timeZone: zone)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = zone
      let parts = calendar.dateComponents([.year, .month, .day, .hour], from: noon)
      XCTAssertEqual(parts.year, day.year)
      XCTAssertEqual(parts.month, day.month)
      XCTAssertEqual(parts.day, day.day)
      XCTAssertEqual(parts.hour, 12)
    }
  }

  func testTitlesUseTheRequestedTimeZoneAndLocale() {
    let title = CalendarHeatmapModel.title(
      CivilDate(year: 2026, month: 11, day: 4), timeZone: auckland)
    XCTAssertEqual(title, "Wed, Nov 4")
  }

  // MARK: Helpers

  /// `yyyy-MM-dd` of a date in UTC, the same text `CivilDate.id` produces.
  private static func id(of date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return CivilDate(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0).id
  }
}
