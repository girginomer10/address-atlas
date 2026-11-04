import AddressAtlasCore
import Foundation

/// One coin's amount (in coins, not dollars) across the saved scans, stacked by
/// state, with the places where the user did something: unstaked, unlocked,
/// received. Pure and `Sendable`.
///
/// Where two neighbouring scans did not read the same sources
/// (`PortfolioAnalytics.runsShareSources`), the series is cut instead of
/// connected, and no amount change is claimed across the cut: a new wallet is
/// not "received" coins.
struct CoinAmountHistoryModel: Equatable, Sendable {
  struct Layer: Identifiable, Equatable, Sendable {
    var id: String { state.rawValue }
    let state: HoldingState
    /// One amount per scan, oldest scan first.
    let values: [Double]
  }

  struct Annotation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      /// Amount moved between states; the total did not change.
      case transfer
      case received
      case sent
    }

    var id: String { "\(runIndex)-\(text)" }
    let kind: Kind
    /// Index of the scan that first shows the change.
    let runIndex: Int
    /// "Unstaked 24.79".
    let text: String
    let amount: Double
  }

  /// Share of the coin's amount below which a change is not worth a label.
  static let annotationThreshold = 0.005

  let symbol: String
  let runIDs: [UUID]
  let dates: [Date]
  /// States that ever hold an amount, bottom of the stack first.
  let layers: [Layer]
  /// Amount per scan across all layers.
  let totals: [Double]
  /// `sourceBreaks[i]` is true when scans `i` and `i + 1` did not read the same
  /// sources. One fewer entry than scans.
  let sourceBreaks: [Bool]
  /// The most telling changes, oldest first.
  let annotations: [Annotation]

  var runCount: Int { runIDs.count }

  /// Runs of scans that can be joined, as index ranges, split at source
  /// changes.
  var segments: [Range<Int>] {
    guard runCount > 0 else { return [] }
    var result: [Range<Int>] = []
    var start = 0
    for (index, isBreak) in sourceBreaks.enumerated() where isBreak {
      result.append(start..<(index + 1))
      start = index + 1
    }
    result.append(start..<runCount)
    return result
  }

  var hasSourceChange: Bool { sourceBreaks.contains(true) }

  var maximumTotal: Double { totals.max() ?? 0 }

  /// The model for one coin, or nil with fewer than two saved scans or when
  /// the coin is in none of them.
  static func make(
    runs: [ScanRunRecord],
    coinKey: String,
    context: ScanSourceContext?,
    maximumAnnotations: Int
  ) -> CoinAmountHistoryModel? {
    let ordered = HistoryRuns.ordered(runs)
    guard ordered.count >= 2 else { return nil }
    let series = PortfolioAnalytics.stackedSeries(
      ordered, by: .state, coin: coinKey, measure: .amount)
    let layers: [Layer] = HoldingState.allCases.compactMap { state in
      guard let layer = series.layers.first(where: { $0.id == state.rawValue }), layer.total > 0
      else { return nil }
      return Layer(state: state, values: layer.values)
    }
    guard !layers.isEmpty else { return nil }
    let totals = ordered.indices.map { index in layers.map { $0.values[index] }.reduce(0, +) }
    var breaks: [Bool] = []
    for index in 0..<(ordered.count - 1) {
      breaks.append(
        !PortfolioAnalytics.runsShareSources(ordered[index], ordered[index + 1], context: context))
    }
    let symbol =
      ordered.reversed().lazy.compactMap { run in
        run.holdings.first { CoinIdentity.key(for: $0) == coinKey }.map(
          CoinIdentity.displaySymbol(for:))
      }.first ?? coinKey
    let annotations = annotations(
      layers: layers, totals: totals, sourceBreaks: breaks, symbol: symbol,
      maximum: maximumAnnotations)
    return CoinAmountHistoryModel(
      symbol: symbol, runIDs: ordered.map(\.id), dates: ordered.map(\.generatedAt),
      layers: layers, totals: totals, sourceBreaks: breaks, annotations: annotations)
  }

  // MARK: Annotations

  /// What a move of `amount` from one state to another is called.
  static func transferVerb(from: HoldingState, to: HoldingState) -> String {
    switch (from, to) {
    case (.staked, .unbonding): "Unstaked"
    case (.unbonding, .liquid): "Unlocked"
    case (.liquid, .staked): "Staked"
    case (.rewards, .liquid): "Claimed"
    default: "Moved"
    }
  }

  static func annotations(
    layers: [Layer],
    totals: [Double],
    sourceBreaks: [Bool],
    symbol: String,
    maximum: Int
  ) -> [Annotation] {
    guard maximum > 0, totals.count >= 2 else { return [] }
    var candidates: [Annotation] = []
    for index in 0..<(totals.count - 1) {
      // Across a change of sources the amount is not comparable.
      guard !sourceBreaks[index] else { continue }
      let scale = max(totals[index], totals[index + 1])
      guard scale > 0 else { continue }
      let threshold = annotationThreshold * scale
      let epsilon = 1e-9 * max(1, scale)
      var gains: [(HoldingState, Double)] = []
      var losses: [(HoldingState, Double)] = []
      for layer in layers {
        let delta = layer.values[index + 1] - layer.values[index]
        // Rewards pile up a little every scan; that is not something the user did.
        if layer.state == .rewards && delta > 0 { continue }
        if delta > epsilon {
          gains.append((layer.state, delta))
        } else if delta < -epsilon {
          losses.append((layer.state, -delta))
        }
      }
      let gained = gains.map(\.1).sorted().reduce(0, +)
      let lost = losses.map(\.1).sorted().reduce(0, +)
      let transfer = min(gained, lost)
      let net = gained - lost
      if transfer >= threshold,
        let from = losses.max(by: { $0.1 < $1.1 })?.0,
        let to = gains.max(by: { $0.1 < $1.1 })?.0
      {
        candidates.append(
          Annotation(
            kind: .transfer, runIndex: index + 1,
            text: "\(transferVerb(from: from, to: to)) \(HistoryChartFormat.amount(transfer))",
            amount: transfer))
      }
      if abs(net) >= threshold {
        candidates.append(
          Annotation(
            kind: net > 0 ? .received : .sent, runIndex: index + 1,
            text: "\(net > 0 ? "Received" : "Sent") \(HistoryChartFormat.amount(abs(net)))",
            amount: abs(net)))
      }
    }
    let largest = candidates.enumerated().sorted { lhs, rhs in
      if lhs.element.amount != rhs.element.amount { return lhs.element.amount > rhs.element.amount }
      return lhs.offset < rhs.offset
    }.prefix(maximum).map(\.element)
    return largest.sorted { lhs, rhs in
      if lhs.runIndex != rhs.runIndex { return lhs.runIndex < rhs.runIndex }
      return lhs.amount > rhs.amount
    }
  }

  // MARK: Wording

  func amountText(_ amount: Double) -> String {
    "\(HistoryChartFormat.amount(amount)) \(symbol)"
  }

  /// Lines for a tooltip on scan `index`.
  func tooltipLines(at index: Int, timeZone: TimeZone) -> [String] {
    guard dates.indices.contains(index) else { return [] }
    var lines = [
      HistoryChartFormat.dayWithWeekday(dates[index], timeZone: timeZone),
      "Total \(amountText(totals[index]))",
    ]
    for layer in layers.reversed() where layer.values[index] > 0 {
      lines.append("\(layer.state.displayName) \(HistoryChartFormat.amount(layer.values[index]))")
    }
    if index > 0, sourceBreaks[index - 1] {
      lines.append("Sources changed since the scan before")
    }
    return lines
  }

  func spokenSummary(timeZone: TimeZone) -> String {
    guard let first = dates.first, let last = dates.last else { return "\(symbol) amount over time." }
    var sentences = [
      "\(symbol) amount over time, \(runCount) scans from \(HistoryChartFormat.day(first, timeZone: timeZone)) to \(HistoryChartFormat.day(last, timeZone: timeZone)).",
      "Latest \(amountText(totals[totals.count - 1])).",
    ]
    for annotation in annotations {
      sentences.append(
        "\(annotation.text) on \(HistoryChartFormat.day(dates[annotation.runIndex], timeZone: timeZone)).")
    }
    if hasSourceChange { sentences.append("Sources changed during this period, so the series is cut there.") }
    return sentences.joined(separator: " ")
  }
}
