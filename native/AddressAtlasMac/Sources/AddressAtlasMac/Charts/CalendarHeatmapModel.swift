import AddressAtlasCore
import Foundation

// MARK: - Calendar arithmetic without time zones

/// A calendar day with no time zone attached (the analytics `CalendarDay` has no
/// public initializer, so the grid builds its own empty days from this).
struct CivilDate: Hashable, Comparable, Sendable {
  let year: Int
  let month: Int
  let day: Int

  init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  init(_ day: CalendarDay) {
    self.init(year: day.year, month: day.month, day: day.day)
  }

  /// `yyyy-MM-dd`.
  var id: String { String(format: "%04d-%02d-%02d", year, month, day) }

  static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }
}

/// Day arithmetic on `CivilDate` that never touches a `Calendar` or a time
/// zone, so a daylight-saving day (23 or 25 hours) is one day like any other.
/// Days are counted from 1970-01-01 (proleptic Gregorian).
enum CivilDay {
  static func number(_ day: CivilDate) -> Int {
    var year = day.year
    let month = day.month
    year -= month <= 2 ? 1 : 0
    let era = (year >= 0 ? year : year - 399) / 400
    let yearOfEra = year - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func day(number: Int) -> CivilDate {
    let shifted = number + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthPart = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
    let month = monthPart < 10 ? monthPart + 3 : monthPart - 9
    return CivilDate(year: year + (month <= 2 ? 1 : 0), month: month, day: day)
  }

  /// 0 for Sunday through 6 for Saturday.
  static func weekday(number: Int) -> Int {
    // 1970-01-01 was a Thursday.
    (((number + 4) % 7) + 7) % 7
  }
}

// MARK: - Model

/// The calendar heatmap: one cell per day, in week columns, coloured by that
/// day's change in value. Days without a scan are empty, never zero.
struct CalendarHeatmapModel: Equatable {
  /// Fewer scan days than this and the calendar says so instead of drawing.
  static let minimumScanDays = 7

  struct Entry: Equatable {
    let point: DailyPortfolioPoint
    /// True when the scans on this day and on the previous scanned day did not
    /// read the same sources, so the change is not only the market.
    let sourcesDiffer: Bool
    /// The previous scanned day's start, for "since 27 Oct".
    let previousDayStart: Date?

    /// The change as a fraction, only when it can be read as a market move.
    var marketChange: Double? {
      sourcesDiffer ? nil : point.changeFraction
    }
  }

  struct Cell: Identifiable, Equatable {
    let day: CivilDate
    let column: Int
    let row: Int
    let entry: Entry?

    var id: String { day.id }
  }

  struct MonthLabel: Equatable {
    let column: Int
    let month: Int
    let year: Int
  }

  let weeks: Int
  /// Calendar convention: 1 is Sunday, 2 Monday, ...
  let firstWeekday: Int
  let cells: [Cell]
  let months: [MonthLabel]
  let scanDayCount: Int
  /// The size of a daily move, as a fraction, drawn at full colour.
  let colorScale: Double
  let latestDay: CivilDate

  var scanCells: [Cell] { cells.filter { $0.entry != nil } }

  /// Row `0...6` of a weekday index (0 = Sunday) in this grid.
  func row(ofWeekday weekday: Int) -> Int {
    ((weekday - (firstWeekday - 1)) % 7 + 7) % 7
  }

  /// The weekday index (0 = Sunday) shown in a row.
  func weekday(ofRow row: Int) -> Int {
    (row + firstWeekday - 1) % 7
  }

  func cell(id: String) -> Cell? { cells.first { $0.id == id } }

  /// Days whose change can be read as a market move (the first scan and days
  /// after a source change have none), best and worst by percentage.
  private var marketCells: [(cell: Cell, change: Double)] {
    scanCells.compactMap { cell in cell.entry?.marketChange.map { (cell, $0) } }
  }

  var bestDay: Cell? {
    marketCells.max { lhs, rhs in
      lhs.change != rhs.change ? lhs.change < rhs.change : lhs.cell.id > rhs.cell.id
    }.flatMap { $0.change > 0 ? $0.cell : nil }
  }

  var worstDay: Cell? {
    marketCells.min { lhs, rhs in
      lhs.change != rhs.change ? lhs.change < rhs.change : lhs.cell.id < rhs.cell.id
    }.flatMap { $0.change < 0 ? $0.cell : nil }
  }

  /// Nil when fewer than `minimumScanDays` days have a scan.
  static func make(
    points: [DailyPortfolioPoint],
    runs: [ScanRunRecord],
    context: ScanSourceContext?,
    firstWeekday: Int,
    minimumWeeks: Int,
    maximumWeeks: Int
  ) -> CalendarHeatmapModel? {
    guard points.count >= minimumScanDays, let first = points.first, let last = points.last else {
      return nil
    }
    let weekStartIndex = ((firstWeekday - 1) % 7 + 7) % 7
    func rowOf(_ number: Int) -> Int {
      ((CivilDay.weekday(number: number) - weekStartIndex) % 7 + 7) % 7
    }
    let firstNumber = CivilDay.number(CivilDate(first.day))
    let lastNumber = CivilDay.number(CivilDate(last.day))
    let lastWeekStart = lastNumber - rowOf(lastNumber)
    let firstWeekStart = firstNumber - rowOf(firstNumber)
    let spanWeeks = (lastWeekStart - firstWeekStart) / 7 + 1
    let weeks = min(max(spanWeeks, minimumWeeks), max(minimumWeeks, maximumWeeks))
    let gridStart = lastWeekStart - (weeks - 1) * 7

    let runsByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let pointsByDay = Dictionary(
      points.map { (CivilDate($0.day), $0) }, uniquingKeysWith: { first, _ in first })
    var entries: [CivilDate: Entry] = [:]
    for point in points {
      var differ = false
      var previousStart: Date?
      if let previousDay = point.previousDay, let previous = pointsByDay[CivilDate(previousDay)] {
        previousStart = previous.dayStart
        if let older = runsByID[previous.runID], let newer = runsByID[point.runID] {
          differ = !PortfolioAnalytics.runsShareSources(older, newer, context: context)
        }
      }
      entries[CivilDate(point.day)] = Entry(
        point: point, sourcesDiffer: differ, previousDayStart: previousStart)
    }

    var cells: [Cell] = []
    var months: [MonthLabel] = []
    var lastMonth: Int?
    if gridStart <= lastNumber {
      for number in gridStart...lastNumber {
        let day = CivilDay.day(number: number)
        let column = (number - gridStart) / 7
        let row = rowOf(number)
        cells.append(Cell(day: day, column: column, row: row, entry: entries[day]))
        if row == 0, day.month != lastMonth {
          months.append(MonthLabel(column: column, month: day.month, year: day.year))
          lastMonth = day.month
        }
      }
    }

    let magnitudes = entries.values.compactMap(\.marketChange).map(abs).sorted()
    let scale: Double
    if magnitudes.isEmpty {
      scale = 0.01
    } else {
      let index = Int((Double(magnitudes.count - 1) * 0.9).rounded(.down))
      scale = max(magnitudes[index], 0.005)
    }
    return CalendarHeatmapModel(
      weeks: weeks, firstWeekday: ((firstWeekday - 1) % 7 + 7) % 7 + 1, cells: cells,
      months: months, scanDayCount: points.count, colorScale: scale, latestDay: CivilDate(last.day))
  }

  // MARK: Colour

  /// How far from neutral a day is drawn, `0` (neutral) to `1` (full colour).
  func intensity(of entry: Entry) -> Double {
    guard let change = entry.marketChange, colorScale > 0 else { return 0 }
    return min(1, abs(change) / colorScale)
  }

  // MARK: Copy

  static func title(_ day: CivilDate, timeZone: TimeZone) -> String {
    HistoryChartFormat.dayWithWeekday(noon(day, timeZone: timeZone), timeZone: timeZone)
  }

  /// A moment inside `day` in `timeZone`, away from midnight so a daylight
  /// saving shift cannot move it to another day.
  static func noon(_ day: CivilDate, timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(
      from: DateComponents(
        timeZone: timeZone, year: day.year, month: day.month, day: day.day, hour: 12))
      ?? Date(timeIntervalSince1970: Double(CivilDay.number(day)) * 86_400 + 43_200)
  }

  /// Lines for a tooltip or the detail panel of one cell.
  static func lines(for cell: Cell, timeZone: TimeZone) -> [String] {
    let title = Self.title(cell.day, timeZone: timeZone)
    guard let entry = cell.entry else { return [title, "No scan"] }
    var lines = [title, HistoryChartFormat.usd(entry.point.totalValueUsd)]
    lines.append(changeLine(entry, timeZone: timeZone))
    if entry.sourcesDiffer {
      lines.append("The wallets or exchanges read were not the same, so this is not a market move.")
    }
    if entry.point.hasUnpricedHoldings {
      lines.append("Some holdings have no price.")
    }
    return lines
  }

  static func changeLine(_ entry: Entry, timeZone: TimeZone) -> String {
    guard let change = entry.point.changeUsd, let start = entry.previousDayStart else {
      return "First scan"
    }
    let since = HistoryChartFormat.day(start, timeZone: timeZone)
    if entry.sourcesDiffer {
      return "Changed \(HistoryChartFormat.signedUsd(change)) since \(since)"
    }
    var text = HistoryChartFormat.signedUsd(change)
    if let fraction = entry.point.changeFraction {
      text += " (\(HistoryChartFormat.signedPercent(fraction)))"
    }
    return "\(text) since \(since)"
  }

  func summary(timeZone: TimeZone) -> String {
    let withScans = scanCells
    var text =
      "Calendar of daily change in value. \(HistoryChartFormat.count(withScans.count, "day")) with a scan "
      + "in the last \(HistoryChartFormat.count(weeks, "week")); days without a scan are empty."
    let market = withScans.compactMap { cell -> (Cell, Double)? in
      guard let change = cell.entry?.marketChange else { return nil }
      return (cell, change)
    }
    if let best = market.max(by: { $0.1 < $1.1 }), best.1 > 0 {
      text +=
        " Best day \(Self.title(best.0.day, timeZone: timeZone)), \(HistoryChartFormat.signedPercent(best.1))."
    }
    if let worst = market.min(by: { $0.1 < $1.1 }), worst.1 < 0 {
      text +=
        " Worst day \(Self.title(worst.0.day, timeZone: timeZone)), \(HistoryChartFormat.signedPercent(worst.1))."
    }
    return text
  }
}
