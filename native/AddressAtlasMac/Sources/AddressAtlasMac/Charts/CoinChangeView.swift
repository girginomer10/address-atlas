import AddressAtlasCore
import SwiftUI

/// Why one coin's value changed since the previous comparable scan: a headline
/// ("ETH changed +$410 since 3 Nov"), a bar that splits the change into price
/// moves and coins arriving or leaving, and one plain sentence for each.
///
/// Coin widgets take `input.coinKey` (a `CoinIdentity.key`) and, when it is
/// nil, the largest coin in `input.holdings`. The earlier scan must have read
/// the same sources as the latest; otherwise the view says there is nothing to
/// compare instead of calling a new wallet a gain. Tapping reports
/// `.coin(key)`.
struct CoinChangeView: View {
  let input: PortfolioChartInput

  @Environment(\.atlasTheme) private var tokens

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let compact = input.density == .compact
    if let key = CoinWidgetResolver.coinKey(for: input) {
      let model = CoinChangeModel.make(
        runs: input.runs, coinKey: key, context: input.sourceContext, timeZone: input.timeZone)
      if let message = model.message {
        HistoryChartMessage(title: message, density: input.density)
      } else {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
          if let headline = model.headline {
            Text(verbatim: headline)
              .font(compact ? style.strongFont : style.displayFont(22, relativeTo: .title2))
              .foregroundStyle(style.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
          CoinChangeEffectRows(effects: model.effects, density: input.density)
          VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            if let price = model.priceSentence { sentence(price, style: style) }
            if let amount = model.amountSentence { sentence(amount, style: style) }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { input.onSelect(.coin(key)) }
        .historyAccessibility(label: model.spokenSummary)
      }
    } else {
      HistoryChartMessage(title: "No holdings to show.", density: input.density)
    }
  }

  private func sentence(_ text: String, style: HistoryChartStyle) -> some View {
    Text(verbatim: text)
      .font(style.bodyFont)
      .foregroundStyle(style.ink2)
      .lineLimit(input.density == .compact ? 2 : nil)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Price and amount effects as signed bars from a shared zero line. The label
/// column takes the width of its longest label (up to a limit, then wraps), so
/// wide theme fonts and large text sizes never cut a label short.
private struct CoinChangeEffectRows: View {
  @Environment(\.atlasTheme) private var tokens
  let effects: [HistoryEffect]
  let density: PortfolioChartDensity

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: density)
    let compact = density == .compact
    let maximum = max(effects.map { abs($0.valueUsd) }.max() ?? 0, 0.01)
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: compact ? 4 : 8) {
      ForEach(effects) { effect in
        GridRow {
          Text(verbatim: effect.title)
            .font(style.captionFont)
            .foregroundStyle(style.ink2)
            .lineLimit(2)
            .frame(maxWidth: compact ? 120 : 190, alignment: .leading)
          bar(for: effect, maximum: maximum, style: style)
            .frame(height: compact ? 10 : 14)
          Text(verbatim: HistoryChartFormat.signedUsd(effect.valueUsd))
            .font(style.numberFont(compact ? 10.5 : 12, relativeTo: .caption))
            .foregroundStyle(
              effect.valueUsd == 0 ? style.ink2 : (effect.valueUsd > 0 ? style.gain : style.loss)
            )
            .lineLimit(1)
            .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(effect.title): \(HistoryChartFormat.signedUsd(effect.valueUsd))")
      }
    }
  }

  private func bar(for effect: HistoryEffect, maximum: Double, style: HistoryChartStyle)
    -> some View
  {
    GeometryReader { proxy in
      let half = proxy.size.width / 2
      let length = half * CGFloat(abs(effect.valueUsd) / maximum)
      ZStack {
        Rectangle().fill(style.ruleSoft).frame(width: 1)
        Rectangle()
          .fill(effect.valueUsd >= 0 ? style.gain : style.loss)
          .frame(width: max(length, effect.valueUsd == 0 ? 0 : 2), height: proxy.size.height)
          .offset(x: effect.valueUsd >= 0 ? length / 2 : -length / 2)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}
