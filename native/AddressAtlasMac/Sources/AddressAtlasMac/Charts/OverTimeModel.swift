import AddressAtlasCore
import Foundation

/// Value over the saved scans, stacked by the user's grouping, with the places
/// where two neighbouring scans did not read the same sources marked so a new
/// wallet is never mistaken for growth.
struct OverTimeModel: Equatable {
  /// Scans drawn at most; older ones are left out so a long history stays
  /// readable and cheap to draw.
  static let maximumRuns = 120

  let series: StackedSeries
  /// `breaks[i]` is true when scans `i` and `i + 1` did not read the same
  /// wallets, exchanges, and manual holdings.
  let breaks: [Bool]
  /// Runs of consecutive scans with no break inside them; each is drawn as one
  /// stacked area, and the space between two of them is the gap.
  let segments: [ClosedRange<Int>]

  var count: Int { series.runIDs.count }
  var hasBreaks: Bool { breaks.contains(true) }
  var maximumTotal: Double { series.totals.max() ?? 0 }

  /// Nil when fewer than two scans exist.
  static func make(
    runs: [ScanRunRecord],
    grouping: PortfolioGrouping,
    context: ScanSourceContext?,
    coin: String? = nil,
    maximumLayers: Int
  ) -> OverTimeModel? {
    let ordered = Array(HistoryRuns.ordered(runs).suffix(maximumRuns))
    guard ordered.count >= 2 else { return nil }
    let series = PortfolioAnalytics.stackedSeries(
      ordered, by: grouping, coin: coin, measure: .valueUsd, maximumLayers: maximumLayers)
    var breaks: [Bool] = []
    for index in 0..<(ordered.count - 1) {
      breaks.append(
        !PortfolioAnalytics.runsShareSources(ordered[index], ordered[index + 1], context: context))
    }
    return OverTimeModel(series: series, breaks: breaks, segments: segments(breaks: breaks))
  }

  /// Splits `breaks.count + 1` scans into runs of scans without a break.
  static func segments(breaks: [Bool]) -> [ClosedRange<Int>] {
    var result: [ClosedRange<Int>] = []
    var start = 0
    for (index, isBreak) in breaks.enumerated() where isBreak {
      result.append(start...index)
      start = index + 1
    }
    result.append(start...breaks.count)
    return result
  }

  /// Cumulative top edge of each layer for each scan: `edges[layer][scan]` is
  /// the sum of layers `0...layer`.
  var edges: [[Double]] {
    var result: [[Double]] = []
    var running = [Double](repeating: 0, count: count)
    for layer in series.layers {
      for index in 0..<count { running[index] += layer.values[index] }
      result.append(running)
    }
    return result
  }

  /// Layers not folded into "Other", in stacking order (largest at the bottom).
  var namedLayers: [StackedLayer] {
    series.layers.filter { $0.id != StackedSeries.otherLayerID }
  }

  func tooltipLines(at index: Int, timeZone: TimeZone) -> [String] {
    guard series.dates.indices.contains(index) else { return [] }
    var lines = [
      HistoryChartFormat.dayWithWeekday(series.dates[index], timeZone: timeZone),
      "Total \(HistoryChartFormat.usd(series.totals[index]))",
    ]
    // Largest layers first, as the user reads the stack from the top.
    let ranked = series.layers.enumerated().map { ($0.element, $0.offset) }
      .filter { $0.0.values[index] > 0 }
      .sorted { lhs, rhs in
        if lhs.0.values[index] != rhs.0.values[index] { return lhs.0.values[index] > rhs.0.values[index] }
        return lhs.1 < rhs.1
      }
    for (layer, _) in ranked.prefix(4) {
      lines.append("\(layer.label) \(HistoryChartFormat.usd(layer.values[index]))")
    }
    if ranked.count > 4 { lines.append("and \(ranked.count - 4) more") }
    if index > 0, breaks[index - 1] {
      lines.append("Sources changed since the previous scan")
    }
    return lines
  }

  func summary(timeZone: TimeZone, grouping: PortfolioGrouping) -> String {
    guard let firstDate = series.dates.first, let lastDate = series.dates.last,
      let firstTotal = series.totals.first, let lastTotal = series.totals.last
    else { return "Value over time" }
    var text =
      "Value over time, stacked by \(grouping.displayName.lowercased()). "
      + "\(HistoryChartFormat.usd(firstTotal)) on \(HistoryChartFormat.day(firstDate, timeZone: timeZone)) "
      + "to \(HistoryChartFormat.usd(lastTotal)) on \(HistoryChartFormat.day(lastDate, timeZone: timeZone)), "
      + "across \(HistoryChartFormat.count(count, "scan"))."
    let breakCount = breaks.filter { $0 }.count
    if breakCount > 0 {
      let dates = breaks.indices.filter { breaks[$0] }.prefix(3).map {
        HistoryChartFormat.day(series.dates[$0 + 1], timeZone: timeZone)
      }
      text += " Sources changed \(breakCount == 1 ? "once" : "\(breakCount) times"), on "
      text += dates.joined(separator: ", ") + ". The chart is broken there."
    }
    return text
  }
}
