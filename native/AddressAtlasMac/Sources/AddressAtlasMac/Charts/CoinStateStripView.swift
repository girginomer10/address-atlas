import AddressAtlasCore
import SwiftUI

/// One coin split by what it can do right now: liquid, staked, unbonding,
/// rewards, on an exchange. A headline with the coin's value, a proportional
/// strip, and one row per state with its amount and value.
///
/// Coin widgets take `input.coinKey` (a `CoinIdentity.key`) and, when it is
/// nil, the largest coin in `input.holdings`. `init(summary:)` needs no
/// history. Tapping a row or a strip segment reports
/// `.slice(grouping: .state, key: <HoldingState raw value>)`.
struct CoinStateStripView: View {
  let input: PortfolioChartInput
  private let summaryOverride: CoinSummary?

  @Environment(\.atlasTheme) private var tokens
  @State private var active: String?

  init(input: PortfolioChartInput) {
    self.input = input
    self.summaryOverride = nil
  }

  /// For callers that already hold the coin's summary and need no history.
  init(
    summary: CoinSummary,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) {
    self.input = PortfolioChartInput(
      holdings: [], coinKey: summary.id, density: density, onSelect: onSelect)
    self.summaryOverride = summary
  }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let compact = input.density == .compact
    if let summary = CoinWidgetResolver.summary(for: input, override: summaryOverride) {
      let model = CoinStateStripModel(summary: summary)
      let segments = model.rows.enumerated().map { index, row in
        CoinWidgetSegment(
          id: row.state.rawValue,
          weight: model.stripWeights[index],
          color: CoinWidgetResolver.stateColor(row.state, tokens: tokens),
          label: "\(row.state.displayName), \(model.rowAmountText(row)), \(model.rowValueText(row))")
      }
      VStack(alignment: .leading, spacing: compact ? 6 : 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: model.headline)
            .font(style.displayFont(compact ? 22 : 32, relativeTo: .title))
            .foregroundStyle(style.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Text(verbatim: model.detailLine)
            .font(style.numberFont(compact ? 11 : 13, relativeTo: .footnote))
            .foregroundStyle(style.ink2)
            .lineLimit(1)
        }
        CoinWidgetSegmentBar(
          segments: segments, height: compact ? 18 : 30, density: input.density,
          active: $active,
          onActivate: { id in select(id) }
        )
        .accessibilityHidden(!compact)
        if compact {
          HistoryLegend(
            items: model.rows.map { row in
              HistoryLegendItem(
                id: row.state.rawValue,
                label: "\(row.state.displayName) \(HistoryChartFormat.percent(model.isPriced ? row.valueShare : row.amountShare))",
                color: CoinWidgetResolver.stateColor(row.state, tokens: tokens).color)
            },
            density: input.density)
        } else {
          VStack(spacing: 0) {
            ForEach(model.rows) { row in
              CoinWidgetRow(
                swatch: CoinWidgetResolver.stateColor(row.state, tokens: tokens),
                title: row.state.displayName,
                detail: detail(for: row, in: summary),
                amount: model.rowAmountText(row),
                value: model.rowValueText(row),
                isActive: active == row.state.rawValue,
                density: input.density,
                onHover: { hovering in
                  if hovering {
                    active = row.state.rawValue
                  } else if active == row.state.rawValue {
                    active = nil
                  }
                },
                action: { select(row.state.rawValue) })
            }
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .historyAccessibility(label: model.spokenSummary)
    } else {
      HistoryChartMessage(
        title: emptyTitle, detail: "Scan again once it has been added.", density: input.density)
    }
  }

  private var emptyTitle: String {
    if let key = input.coinKey, !key.isEmpty {
      return "No \(CoinIdentity.key(forSymbol: key)) in this scan."
    }
    return "No holdings to show."
  }

  private func detail(for row: CoinStateStripModel.Row, in summary: CoinSummary) -> String? {
    guard row.state == .unbonding,
      let unlock = summary.states.first(where: { $0.state == .unbonding })?.earliestUnlock
    else { return nil }
    return "Free on \(HistoryChartFormat.day(unlock, timeZone: input.timeZone))"
  }

  private func select(_ key: String) {
    input.onSelect(.slice(grouping: .state, key: key))
  }
}
