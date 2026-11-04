import AddressAtlasCore
import Foundation

/// The waterfall behind "What changed": the previous scan's total, one step per
/// coin, and the latest scan's total, plus the split of the whole change into
/// price moves and coins coming or going.
///
/// It compares only the latest two scans, and only when they read the same
/// sources. Otherwise the difference would be partly a wallet appearing, and the
/// view says so instead of drawing it.
struct WhatChangedModel: Equatable {
  enum Outcome: Equatable {
    case notEnoughScans
    /// The latest two scans did not read the same sources.
    case notComparable
    /// Same sources and the same coins at the same value.
    case unchanged(Waterfall)
    case ready(Waterfall)
  }

  struct Bar: Equatable, Identifiable {
    enum Kind: Equatable {
      case start
      case change
      case end
    }

    let id: String
    let kind: Kind
    let label: String
    /// Set for a single coin; selects it.
    let coinKey: String?
    /// Set for the two totals; selects that scan.
    let runID: UUID?
    /// Signed change for a coin bar; the total for a total bar.
    let value: Double
    /// Where the bar starts and ends on the value axis (low <= high).
    let low: Double
    let high: Double
    /// The running total after this bar.
    let level: Double
    let priceEffectUsd: Double
    let amountEffectUsd: Double
    let valuationGapUsd: Double
    /// Coins folded into this bar (1 for a single coin, 0 for totals).
    let coinCount: Int
    let amountDescription: String?

    var isSelectable: Bool { coinKey != nil || runID != nil }
  }

  struct Waterfall: Equatable {
    let bars: [Bar]
    let previousDate: Date
    let latestDate: Date
    let previousRunID: UUID
    let latestRunID: UUID
    let startTotal: Double
    let endTotal: Double
    let priceEffectUsd: Double
    let amountEffectUsd: Double
    let valuationGapUsd: Double
    let hasUnpricedHoldings: Bool

    var change: Double { endTotal - startTotal }
    var changeFraction: Double? { startTotal > 0 ? change / startTotal : nil }
    var coinBars: [Bar] { bars.filter { $0.kind == .change } }
  }

  /// Value axis for a waterfall: a zero baseline unless every level sits in a
  /// narrow band near the top, in which case it starts just below the lowest
  /// level so the steps are readable. `isZeroBased` tells the view to say so.
  struct Axis: Equatable {
    let low: Double
    let high: Double
    let isZeroBased: Bool
  }

  /// Every value the axis has to reach: both totals and every step's ends.
  static func levels(of waterfall: Waterfall) -> [Double] {
    waterfall.bars.flatMap { bar -> [Double] in
      bar.kind == .change ? [bar.low, bar.high] : [bar.level]
    }
  }

  static func axis(levels: [Double]) -> Axis {
    let finite = levels.filter(\.isFinite)
    guard let lowest = finite.min(), let highest = finite.max(), highest > 0 else {
      return Axis(low: 0, high: 1, isZeroBased: true)
    }
    let span = highest - lowest
    if lowest <= 0 || span / highest > 0.4 {
      let padded = highest + max(span * 0.12, highest * 0.02)
      return Axis(low: 0, high: padded, isZeroBased: true)
    }
    let pad = max(span * 0.35, highest * 0.004)
    let step = HistoryChartMath.niceCeiling((span + 2 * pad) / 4)
    let low = max(0, ((lowest - pad) / step).rounded(.down) * step)
    let high = ((highest + pad) / step).rounded(.up) * step
    return Axis(low: low, high: max(high, low + step), isZeroBased: false)
  }

  /// The most coin steps drawn (one more bar folds the rest).
  static func make(
    runs: [ScanRunRecord],
    context: ScanSourceContext?,
    maximumCoinBars: Int
  ) -> Outcome {
    let ordered = HistoryRuns.ordered(runs)
    guard ordered.count >= 2, let latest = ordered.last else { return .notEnoughScans }
    let previous = ordered[ordered.count - 2]
    guard PortfolioAnalytics.runsShareSources(previous, latest, context: context) else {
      return .notComparable
    }
    let attribution = PortfolioAnalytics.attribution(from: previous, to: latest, context: context)
    let waterfall = waterfall(attribution: attribution, maximumCoinBars: maximumCoinBars)
    return attribution.coins.isEmpty ? .unchanged(waterfall) : .ready(waterfall)
  }

  static func waterfall(attribution: ChangeAttribution, maximumCoinBars: Int) -> Waterfall {
    let coins = attribution.coins
    let limit = max(1, maximumCoinBars)
    let shown: [CoinChange]
    let folded: [CoinChange]
    if coins.count > limit {
      shown = Array(coins.prefix(limit - 1))
      folded = Array(coins.dropFirst(limit - 1))
    } else {
      shown = coins
      folded = []
    }

    var bars: [Bar] = []
    var level = attribution.olderTotalUsd
    bars.append(
      Bar(
        id: "start", kind: .start, label: "", coinKey: nil, runID: attribution.olderRunID,
        value: level, low: 0, high: level, level: level, priceEffectUsd: 0, amountEffectUsd: 0,
        valuationGapUsd: 0, coinCount: 0, amountDescription: nil))
    func step(
      id: String, label: String, key: String?, delta: Double, price: Double, amount: Double,
      gap: Double, count: Int, amountDescription: String?
    ) {
      let before = level
      level += delta
      bars.append(
        Bar(
          id: id, kind: .change, label: label, coinKey: key, runID: nil, value: delta,
          low: min(before, level), high: max(before, level), level: level,
          priceEffectUsd: price, amountEffectUsd: amount, valuationGapUsd: gap, coinCount: count,
          amountDescription: amountDescription))
    }
    for coin in shown {
      step(
        id: coin.id, label: coin.symbol, key: coin.id, delta: coin.deltaUsd,
        price: coin.priceEffectUsd, amount: coin.amountEffectUsd, gap: coin.valuationGapUsd,
        count: 1, amountDescription: amountText(coin))
    }
    if !folded.isEmpty {
      step(
        id: "other", label: "Other", key: nil,
        delta: HistoryChartMath.sum(folded.map(\.deltaUsd)),
        price: HistoryChartMath.sum(folded.map(\.priceEffectUsd)),
        amount: HistoryChartMath.sum(folded.map(\.amountEffectUsd)),
        gap: HistoryChartMath.sum(folded.map(\.valuationGapUsd)),
        count: folded.count, amountDescription: nil)
    }
    bars.append(
      Bar(
        id: "end", kind: .end, label: "", coinKey: nil, runID: attribution.newerRunID,
        value: attribution.newerTotalUsd, low: 0, high: attribution.newerTotalUsd,
        level: attribution.newerTotalUsd, priceEffectUsd: 0, amountEffectUsd: 0,
        valuationGapUsd: 0, coinCount: 0, amountDescription: nil))

    return Waterfall(
      bars: bars, previousDate: attribution.olderDate, latestDate: attribution.newerDate,
      previousRunID: attribution.olderRunID, latestRunID: attribution.newerRunID,
      startTotal: attribution.olderTotalUsd, endTotal: attribution.newerTotalUsd,
      priceEffectUsd: attribution.priceEffectUsd, amountEffectUsd: attribution.amountEffectUsd,
      valuationGapUsd: attribution.valuationGapUsd,
      hasUnpricedHoldings: attribution.hasUnpricedHoldings)
  }

  private static func amountText(_ coin: CoinChange) -> String? {
    switch coin.status {
    case .added: return "New: \(HistoryChartFormat.amount(coin.newerAmount)) \(coin.symbol)"
    case .removed: return "No longer held: \(HistoryChartFormat.amount(coin.olderAmount)) \(coin.symbol)"
    case .changed:
      guard coin.olderAmount != coin.newerAmount else { return nil }
      return
        "\(HistoryChartFormat.amount(coin.olderAmount)) to \(HistoryChartFormat.amount(coin.newerAmount)) \(coin.symbol)"
    }
  }

  // MARK: Copy

  static func headline(_ waterfall: Waterfall, timeZone: TimeZone) -> String {
    let since = HistoryChartFormat.day(waterfall.previousDate, timeZone: timeZone)
    let change = waterfall.change
    if abs(change) < 0.005 { return "No change since \(since)" }
    let word = change > 0 ? "Up" : "Down"
    var text = "\(word) \(HistoryChartFormat.usd(abs(change))) since \(since)"
    if let fraction = waterfall.changeFraction, abs(fraction) >= 0.0005 {
      text += " (\(HistoryChartFormat.signedPercent(fraction)))"
    }
    return text
  }

  static func subline(_ waterfall: Waterfall) -> String {
    "\(HistoryChartFormat.usd(waterfall.startTotal)) to \(HistoryChartFormat.usd(waterfall.endTotal))"
  }

  static let notComparableTitle =
    "Your sources changed since the last scan, so this compares different things."

  static func tooltipLines(_ bar: Bar, waterfall: Waterfall, timeZone: TimeZone) -> [String] {
    switch bar.kind {
    case .start:
      return [
        HistoryChartFormat.day(waterfall.previousDate, timeZone: timeZone),
        HistoryChartFormat.usd(bar.value),
      ]
    case .end:
      return [
        HistoryChartFormat.day(waterfall.latestDate, timeZone: timeZone),
        HistoryChartFormat.usd(bar.value),
      ]
    case .change:
      let title =
        bar.coinCount > 1
        ? "\(bar.coinCount) other coins \(HistoryChartFormat.delta(bar.value))"
        : "\(bar.label) \(HistoryChartFormat.delta(bar.value))"
      var lines = [title]
      if bar.coinCount == 1 { if let text = bar.amountDescription { lines.append(text) } }
      lines.append("Price \(HistoryChartFormat.delta(bar.priceEffectUsd))")
      lines.append("Coins in or out \(HistoryChartFormat.delta(bar.amountEffectUsd))")
      if abs(bar.valuationGapUsd) > 0.005 {
        lines.append("Price missing in one scan \(HistoryChartFormat.delta(bar.valuationGapUsd))")
      }
      return lines
    }
  }

  static func summary(_ waterfall: Waterfall, timeZone: TimeZone) -> String {
    var text = headline(waterfall, timeZone: timeZone) + ". "
    text += "From \(HistoryChartFormat.usd(waterfall.startTotal)) to \(HistoryChartFormat.usd(waterfall.endTotal)). "
    let coins = waterfall.coinBars.prefix(5).map {
      "\($0.coinCount > 1 ? "\($0.coinCount) other coins" : $0.label) \(HistoryChartFormat.delta($0.value))"
    }
    if !coins.isEmpty { text += "By coin: " + coins.joined(separator: ", ") + ". " }
    text += "Price moves \(HistoryChartFormat.delta(waterfall.priceEffectUsd)), "
    text += "coins in or out \(HistoryChartFormat.delta(waterfall.amountEffectUsd))."
    return text
  }
}
