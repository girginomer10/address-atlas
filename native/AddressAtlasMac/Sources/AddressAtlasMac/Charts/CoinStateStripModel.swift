import AddressAtlasCore
import Foundation

/// What the coin state strip shows, from one coin's summary: the headline, and
/// one row per state the coin is in (liquid, staked, unbonding, rewards, on
/// exchange). Pure and `Sendable`.
struct CoinStateStripModel: Equatable, Sendable {
  struct Row: Identifiable, Equatable, Sendable {
    var id: String { state.rawValue }
    let state: HoldingState
    let amount: Double
    let valueUsd: Double
    /// Share of the coin's priced value, 0...1 (zero when nothing is priced).
    let valueShare: Double
    /// Share of the coin's amount, 0...1.
    let amountShare: Double

    var amountText: String { HistoryChartFormat.amount(amount) }
  }

  let symbol: String
  let totalAmount: Double
  let valueUsd: Double
  let priceUsd: Double?
  /// States with an amount, in `HoldingState` order.
  let rows: [Row]

  init(summary: CoinSummary) {
    symbol = summary.symbol
    totalAmount = summary.totalAmount
    valueUsd = summary.valueUsd
    priceUsd = summary.priceUsd
    let total = summary.states.map(\.amount).reduce(0, +)
    rows = summary.states.filter { $0.amount > 0 || $0.valueUsd > 0 }.map { state in
      Row(
        state: state.state, amount: state.amount, valueUsd: state.valueUsd,
        valueShare: state.share, amountShare: total > 0 ? state.amount / total : 0)
    }
  }

  var isPriced: Bool { priceUsd != nil && valueUsd > 0 }

  /// Weights for the strip: value when the coin is priced, amount otherwise,
  /// so an unpriced coin still gets an honest proportional strip.
  var stripWeights: [Double] {
    rows.map { isPriced ? $0.valueUsd : $0.amount }
  }

  /// "$1,904.00" or the amount when there is no price.
  var headline: String {
    isPriced
      ? HistoryChartFormat.usd(valueUsd, cents: true)
      : "\(HistoryChartFormat.amount(totalAmount)) \(symbol)"
  }

  /// "310.2 ATOM \u{00B7} $6.80" (amount and price of one coin), or "No price
  /// yet" for an unpriced coin.
  var detailLine: String {
    guard let priceUsd, isPriced else { return "No price yet" }
    return "\(HistoryChartFormat.amount(totalAmount)) \(symbol) \u{00B7} \(HistoryChartFormat.usd(priceUsd, cents: true))"
  }

  func rowAmountText(_ row: Row) -> String {
    "\(row.amountText) \(symbol)"
  }

  func rowValueText(_ row: Row) -> String {
    CoinWidgetResolver.valueText(row.valueUsd, priced: isPriced)
  }

  /// One sentence for VoiceOver.
  var spokenSummary: String {
    let parts = rows.map { "\($0.state.displayName) \(rowAmountText($0))" }
    return "\(symbol), \(headline). " + parts.joined(separator: ", ")
  }
}
