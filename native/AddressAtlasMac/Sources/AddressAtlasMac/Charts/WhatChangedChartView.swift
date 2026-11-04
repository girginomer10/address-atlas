import AddressAtlasCore
import SwiftUI

/// What changed since the previous scan, as a waterfall: the previous total, one
/// step per coin (green added value, red took it away), and the latest total,
/// with the split between price moves and coins coming or going underneath.
///
/// It only compares the latest two scans when they read the same sources. If
/// they did not, it says so in words instead of drawing a chart that would
/// credit a new wallet to the market. Hover (Mac) or tap (iOS) shows a bar's
/// detail; clicking or tapping reports `.coin(key)` for a coin and `.run(id)` for
/// either total.
struct WhatChangedChartView: View {
  let input: PortfolioChartInput
  private let outcome: WhatChangedModel.Outcome

  @Environment(\.atlasTheme) private var tokens
  @ScaledMetric(relativeTo: .caption) private var textScale: CGFloat = 1
  @State private var active: Int?

  init(input: PortfolioChartInput) {
    self.input = input
    outcome = WhatChangedModel.make(
      runs: input.runs, context: input.sourceContext,
      maximumCoinBars: input.density == .compact ? 4 : 7)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    switch outcome {
    case .notEnoughScans:
      HistoryChartMessage(
        title: "Not enough scans yet",
        detail: "Save another scan to see what changed.", density: input.density)
    case .notComparable:
      HistoryChartMessage(
        title: WhatChangedModel.notComparableTitle,
        detail: "Scan again to compare like with like.", density: input.density)
    case .unchanged(let waterfall):
      HistoryChartMessage(
        title: WhatChangedModel.headline(waterfall, timeZone: input.timeZone),
        detail: "No coin changed in amount or price.", density: input.density)
    case .ready(let waterfall):
      content(waterfall)
    }
  }

  // MARK: Layout

  @ViewBuilder
  private func content(_ waterfall: WhatChangedModel.Waterfall) -> some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let axis = WhatChangedModel.axis(levels: WhatChangedModel.levels(of: waterfall))
    VStack(alignment: .leading, spacing: isCompact ? 5 : 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: WhatChangedModel.headline(waterfall, timeZone: input.timeZone))
          .font(isCompact ? style.strongFont : style.displayFont(20, relativeTo: .title3))
          .foregroundStyle(style.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        if !isCompact {
          Text(verbatim: WhatChangedModel.subline(waterfall))
            .font(style.captionFont)
            .foregroundStyle(style.ink3)
        }
      }
      .accessibilityHidden(true)
      GeometryReader { proxy in
        chart(waterfall: waterfall, axis: axis, style: style, size: proxy.size)
      }
      .frame(minHeight: isCompact ? 70 : 140)
      HistoryEffectsBar(
        effects: HistoryEffects.effects(
          price: waterfall.priceEffectUsd, amount: waterfall.amountEffectUsd,
          valuationGap: waterfall.valuationGapUsd),
        density: input.density)
      footnotes(waterfall: waterfall, axis: axis, style: style)
    }
  }

  @ViewBuilder
  private func footnotes(
    waterfall: WhatChangedModel.Waterfall, axis: WhatChangedModel.Axis, style: HistoryChartStyle
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if !axis.isZeroBased {
        Text(verbatim: "The scale starts at \(HistoryChartFormat.usd(axis.low)).")
          .font(style.smallFont)
          .foregroundStyle(style.ink3)
      }
      if waterfall.hasUnpricedHoldings {
        Text(verbatim: "Some holdings have no price, so totals are a lower bound.")
          .font(style.smallFont)
          .foregroundStyle(style.ink3)
      }
    }
  }

  // MARK: Chart

  private struct Plot {
    var rect: CGRect
    var axis: WhatChangedModel.Axis
    var count: Int

    var slotWidth: CGFloat { rect.width / CGFloat(max(1, count)) }

    func slot(_ index: Int) -> CGRect {
      CGRect(
        x: rect.minX + slotWidth * CGFloat(index), y: rect.minY, width: slotWidth,
        height: rect.height)
    }

    func barRect(centered index: Int) -> CGRect {
      let slot = slot(index)
      let width = min(slot.width * 0.66, 64)
      return CGRect(x: slot.midX - width / 2, y: slot.minY, width: width, height: slot.height)
    }

    func y(_ value: Double) -> CGFloat {
      let span = axis.high - axis.low
      guard span > 0 else { return rect.maxY }
      return rect.maxY - rect.height * CGFloat(min(max((value - axis.low) / span, 0), 1))
    }
  }

  private func plot(waterfall: WhatChangedModel.Waterfall, axis: WhatChangedModel.Axis, size: CGSize)
    -> Plot
  {
    let top: CGFloat = (isCompact ? 14 : 18) * textScale
    let bottom: CGFloat = (isCompact ? 16 : 22) * textScale
    let rect = CGRect(
      x: 2, y: top, width: max(10, size.width - 4), height: max(10, size.height - top - bottom))
    return Plot(rect: rect, axis: axis, count: waterfall.bars.count)
  }

  @ViewBuilder
  private func chart(
    waterfall: WhatChangedModel.Waterfall, axis: WhatChangedModel.Axis, style: HistoryChartStyle,
    size: CGSize
  ) -> some View {
    let plot = plot(waterfall: waterfall, axis: axis, size: size)
    let hovered = active
    let timeZone = input.timeZone
    let onSelect = input.onSelect
    Canvas { context, canvasSize in
      draw(
        &context, size: canvasSize, waterfall: waterfall, style: style, plot: plot,
        hovered: hovered, timeZone: timeZone)
    }
    .historyPointer(
      active: $active,
      hitTest: { point in
        guard plot.rect.insetBy(dx: 0, dy: -20).contains(point) else { return nil }
        let index = Int((point.x - plot.rect.minX) / max(1, plot.slotWidth))
        return waterfall.bars.indices.contains(index) ? index : nil
      },
      onActivate: { index in
        guard waterfall.bars.indices.contains(index) else { return }
        let bar = waterfall.bars[index]
        if let key = bar.coinKey {
          onSelect(.coin(key))
        } else if let runID = bar.runID {
          onSelect(.run(runID))
        }
      }
    )
    .accessibilityChildren {
      ForEach(Array(waterfall.bars.enumerated()), id: \.offset) { _, bar in
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(
            WhatChangedModel.tooltipLines(bar, waterfall: waterfall, timeZone: timeZone)
              .joined(separator: ", "))
          .accessibilityAddTraits(bar.isSelectable ? .isButton : [])
          .accessibilityAction {
            if let key = bar.coinKey {
              onSelect(.coin(key))
            } else if let runID = bar.runID {
              onSelect(.run(runID))
            }
          }
      }
    }
    .historyAccessibility(label: WhatChangedModel.summary(waterfall, timeZone: timeZone))
  }

  // MARK: Drawing

  private func draw(
    _ context: inout GraphicsContext,
    size: CGSize,
    waterfall: WhatChangedModel.Waterfall,
    style: HistoryChartStyle,
    plot: Plot,
    hovered: Int?,
    timeZone: TimeZone
  ) {
    var baseline = Path()
    baseline.move(to: CGPoint(x: plot.rect.minX, y: plot.rect.maxY))
    baseline.addLine(to: CGPoint(x: plot.rect.maxX, y: plot.rect.maxY))
    context.stroke(baseline, with: .color(style.rule), lineWidth: 1)

    let borderWidth = style.markBorderWidth
    var previousRight: CGFloat?
    var previousLevelY: CGFloat?
    for (index, bar) in waterfall.bars.enumerated() {
      let column = plot.barRect(centered: index)
      let top = plot.y(bar.high)
      let bottom = bar.kind == .change ? plot.y(bar.low) : plot.rect.maxY
      let rect = CGRect(
        x: column.minX, y: min(top, bottom), width: column.width,
        height: max(abs(bottom - top), 2))
      let color: Color
      switch bar.kind {
      case .start: color = style.ink3
      case .end: color = style.ink
      case .change: color = bar.value >= 0 ? style.gain : style.loss
      }
      // Connector from the previous bar's running level.
      if let previousRight, let previousLevelY {
        var connector = Path()
        connector.move(to: CGPoint(x: previousRight, y: previousLevelY))
        connector.addLine(to: CGPoint(x: rect.minX, y: previousLevelY))
        context.stroke(
          connector, with: .color(style.ink3), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
      }
      previousRight = rect.maxX
      previousLevelY = plot.y(bar.level)

      let shape = RoundedRectangle(
        cornerRadius: style.blockRadius(for: min(rect.width, rect.height)), style: .continuous
      ).path(in: rect)
      let isHot = hovered == index
      context.fill(shape, with: .color(color.opacity(hovered == nil || isHot ? 1 : 0.55)))
      if borderWidth > 0 {
        context.stroke(shape, with: .color(style.ink), lineWidth: borderWidth)
      }

      // Value above the bar, name or date below the axis.
      let slotWidth = plot.slotWidth
      let valueText: String
      switch bar.kind {
      case .change: valueText = HistoryChartFormat.delta(bar.value)
      default:
        valueText =
          slotWidth < 62 ? HistoryChartFormat.usdCompact(bar.value) : HistoryChartFormat.usd(bar.value)
      }
      if let fitted = context.historyFit(
        valueText, font: style.smallFont, maxWidth: slotWidth + 8, minimumCharacters: 3)
      {
        let tint: Color
        switch bar.kind {
        case .change: tint = bar.value >= 0 ? style.gain : style.loss
        default: tint = style.ink2
        }
        context.historyDraw(
          fitted, font: style.smallFont, color: tint,
          at: CGPoint(x: column.midX, y: rect.minY - 3), anchor: .bottom)
      }
      let name: String
      switch bar.kind {
      case .start: name = HistoryChartFormat.day(waterfall.previousDate, timeZone: timeZone)
      case .end: name = HistoryChartFormat.day(waterfall.latestDate, timeZone: timeZone)
      case .change: name = bar.label
      }
      if let fitted = context.historyFit(
        name, font: style.captionFont, maxWidth: slotWidth - 2, minimumCharacters: 2)
      {
        context.historyDraw(
          fitted, font: style.captionFont, color: style.ink2,
          at: CGPoint(x: column.midX, y: plot.rect.maxY + 5), anchor: .top)
      }
    }

    if let hovered, waterfall.bars.indices.contains(hovered) {
      let bar = waterfall.bars[hovered]
      let column = plot.barRect(centered: hovered)
      HistoryTooltip(
        lines: WhatChangedModel.tooltipLines(bar, waterfall: waterfall, timeZone: timeZone),
        anchor: CGPoint(x: column.midX, y: plot.y(bar.high))
      ).draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
    }
  }
}
