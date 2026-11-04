import AddressAtlasCore
import Foundation

/// The numbers and words behind the concentration gauge: how much sits in the
/// largest group, how many equal holdings the portfolio behaves like, and where
/// that falls between "spread out" and "concentrated".
struct ConcentrationModel: Equatable {
  let concentration: Concentration
  let grouping: PortfolioGrouping

  init(holdings: [TrackedAsset], grouping: PortfolioGrouping) {
    self.grouping = grouping
    concentration = PortfolioAnalytics.concentration(holdings, by: grouping)
  }

  var hasValue: Bool { concentration.totalValueUsd > 0 && concentration.groupCount > 0 }

  // MARK: Words

  /// "coin", "network", ...
  var singular: String {
    switch grouping {
    case .asset: "coin"
    case .network: "network"
    case .source: "wallet or exchange"
    case .state: "state"
    case .kind: "type"
    }
  }

  /// What equal-sized groups are called in the reading: "holdings" for coins.
  var equalGroups: String {
    switch grouping {
    case .asset: "holdings"
    case .network: "networks"
    case .source: "wallets or exchanges"
    case .state: "states"
    case .kind: "types"
    }
  }

  static func effectiveText(_ value: Double) -> String {
    if value >= 10 { return String(Int(value.rounded())) }
    return value.formatted(
      .number.precision(.fractionLength(1)).locale(HistoryChartFormat.locale))
  }

  var topShareText: String { HistoryChartFormat.percent(concentration.topShare) }

  /// One plain line: "57% is in one coin. Your portfolio behaves like 2.6 equal
  /// holdings."
  var reading: String {
    guard hasValue else { return "Nothing has a price yet, so there is nothing to measure." }
    if concentration.groupCount == 1 {
      return "All of it is in one \(singular)."
    }
    return
      "\(topShareText) is in one \(singular). Your portfolio behaves like "
      + "\(Self.effectiveText(concentration.effectiveHoldings)) equal \(equalGroups)."
  }

  var levelTitle: String {
    switch concentration.level {
    case .diversified?: "Spread out"
    case .moderate?: "Fairly concentrated"
    case .concentrated?: "Concentrated"
    case nil: "No priced value"
    }
  }

  // MARK: Gauge

  /// Where `herfindahl` falls on the gauge, 0 (spread out) to 1 (everything in
  /// one group). The three bands (below 0.15, 0.15 to 0.25, above 0.25) take a
  /// third of the dial each, so the needle moves visibly where it matters.
  static func gaugePosition(herfindahl: Double) -> Double {
    guard herfindahl.isFinite, herfindahl > 0 else { return 0 }
    let h = min(herfindahl, 1)
    if h < 0.15 { return h / 0.15 / 3 }
    if h < 0.25 { return 1.0 / 3 + (h - 0.15) / 0.10 / 3 }
    return 2.0 / 3 + (h - 0.25) / 0.75 / 3
  }

  var gaugePosition: Double {
    Self.gaugePosition(herfindahl: concentration.herfindahlIndex)
  }

  func selection(for entry: ConcentrationEntry) -> PortfolioChartSelection {
    grouping == .asset ? .coin(entry.id) : .slice(grouping: grouping, key: entry.id)
  }

  var spokenSummary: String {
    var text = reading
    if hasValue {
      text += " \(levelTitle)."
      let leaders = concentration.leaders.map {
        "\($0.label) \(HistoryChartFormat.percent($0.share))"
      }
      if !leaders.isEmpty { text += " Largest: " + leaders.joined(separator: ", ") + "." }
    }
    return text
  }
}
