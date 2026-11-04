import AddressAtlasCore
import SwiftUI

/// How much of one coin you hold yourself versus on exchanges (and, when you
/// entered a holding by hand, how much has unknown custody): a big percentage,
/// one sentence, a proportional bar and the amounts per side with the wallets
/// and exchanges behind them.
///
/// Coin widgets take `input.coinKey` (a `CoinIdentity.key`) and, when it is
/// nil, the largest coin in `input.holdings`. `init(summary:)` needs no
/// history. Tapping a wallet or exchange reports
/// `.slice(grouping: .source, key: <source id>)`; tapping a side header reports
/// the first source of that side.
struct CoinCustodyView: View {
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

  private static let maximumSources = 3

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let compact = input.density == .compact
    if let summary = CoinWidgetResolver.summary(for: input, override: summaryOverride) {
      let model = CoinCustodyModel(summary: summary)
      let segments = model.parts.map { part in
        CoinWidgetSegment(
          id: part.side.rawValue, weight: part.amount, color: color(part.side),
          hatched: part.side == .manual,
          label: "\(part.side.title), \(model.amountText(part.amount))")
      }
      VStack(alignment: .leading, spacing: compact ? 6 : 10) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: model.headline)
            .font(style.displayFont(compact ? 26 : 40, relativeTo: .largeTitle))
            .foregroundStyle(style.ink)
            .lineLimit(1)
          Text(verbatim: "self-custody")
            .font(style.captionFont)
            .foregroundStyle(style.ink3)
            .lineLimit(1)
        }
        Text(verbatim: model.sentence)
          .font(style.bodyFont)
          .foregroundStyle(style.ink2)
          .lineLimit(compact ? 2 : 3)
          .fixedSize(horizontal: false, vertical: true)
        CoinWidgetSegmentBar(
          segments: segments, height: compact ? 18 : 30, density: input.density,
          active: $active,
          onActivate: { side in selectSide(side, in: model) }
        )
        .accessibilityHidden(!compact)
        if compact {
          HistoryLegend(
            items: model.parts.map { part in
              HistoryLegendItem(
                id: part.id,
                label: "\(part.side.shortTitle) \(HistoryChartFormat.amount(part.amount))",
                color: color(part.side).color)
            },
            density: input.density)
        } else {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.parts) { part in
              partBlock(part, model: model, style: style)
            }
            if let note = model.manualNote {
              Text(verbatim: note)
                .font(style.captionFont)
                .foregroundStyle(style.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
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

  @ViewBuilder
  private func partBlock(
    _ part: CoinCustodyModel.Part, model: CoinCustodyModel, style: HistoryChartStyle
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      CoinWidgetRow(
        swatch: color(part.side),
        hatched: part.side == .manual,
        title: part.side.title,
        amount: model.amountText(part.amount),
        value: model.valueText(part.valueUsd),
        isActive: active == part.side.rawValue,
        density: input.density,
        onHover: { hovering in
          if hovering {
            active = part.side.rawValue
          } else if active == part.side.rawValue {
            active = nil
          }
        },
        action: { selectSide(part.side.rawValue, in: model) })
      // Which wallets and exchanges make up this side.
      ForEach(Array(part.sources.prefix(Self.maximumSources))) { source in
        HStack(spacing: 8) {
          Text(verbatim: source.label)
            .font(style.captionFont)
            .foregroundStyle(style.ink2)
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(verbatim: model.amountText(source.amount))
            .font(style.numberFont(11, relativeTo: .caption))
            .foregroundStyle(style.ink3)
            .lineLimit(1)
        }
        .padding(.leading, 36)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { input.onSelect(.slice(grouping: .source, key: source.id)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.label), \(model.amountText(source.amount))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { input.onSelect(.slice(grouping: .source, key: source.id)) }
      }
      if part.sources.count > Self.maximumSources {
        Text(verbatim: "and \(part.sources.count - Self.maximumSources) more")
          .font(style.smallFigureFont)
          .foregroundStyle(style.ink3)
          .padding(.leading, 36)
      }
    }
  }

  private func color(_ side: CoinCustodyModel.Side) -> AtlasRGB {
    switch side {
    case .wallet: tokens.chart.kind(.native)
    case .exchange: tokens.chart.kind(.exchange)
    case .manual: tokens.chart.kind(.manual)
    }
  }

  private func selectSide(_ raw: String, in model: CoinCustodyModel) {
    guard let side = CoinCustodyModel.Side(rawValue: raw),
      let source = model.part(side)?.sources.first
    else { return }
    input.onSelect(.slice(grouping: .source, key: source.id))
  }

  private var emptyTitle: String {
    if let key = input.coinKey, !key.isEmpty {
      return "No \(CoinIdentity.key(forSymbol: key)) in this scan."
    }
    return "No holdings to show."
  }
}
