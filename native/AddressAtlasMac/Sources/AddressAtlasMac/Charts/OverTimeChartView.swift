import AddressAtlasCore
import SwiftUI

/// Portfolio value over the saved scans, stacked by the chosen grouping.
///
/// The chart is cut where two neighbouring scans did not read the same wallets,
/// exchanges, and manual holdings: a dashed rule and a shaded gap replace the
/// connecting area, so adding a wallet is never drawn as growth. Layers beyond
/// the first few are folded into one "Other" layer. Hover (Mac) or tap (iOS)
/// shows the nearest scan; clicking or tapping reports `.run(id)`.
struct OverTimeChartView: View {
  let input: PortfolioChartInput
  private let model: OverTimeModel?

  @Environment(\.atlasTheme) private var tokens
  @ScaledMetric(relativeTo: .caption) private var textScale: CGFloat = 1
  @State private var active: Int?

  init(input: PortfolioChartInput) {
    self.input = input
    model = OverTimeModel.make(
      runs: input.runs, grouping: input.grouping, context: input.sourceContext, coin: input.coinKey,
      maximumLayers: input.density == .compact ? 5 : 7)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    if let model, model.maximumTotal > 0 {
      let colors = layerColors(model: model, style: style)
      VStack(alignment: .leading, spacing: isCompact ? 4 : 8) {
        GeometryReader { proxy in
          chart(model: model, colors: colors, style: style, size: proxy.size)
        }
        HistoryLegend(items: legendItems(model: model, colors: colors), density: input.density)
      }
    } else if model == nil {
      HistoryChartMessage(
        title: "Not enough scans yet",
        detail: "Two saved scans are needed to chart value over time.", density: input.density)
    } else {
      HistoryChartMessage(
        title: "No priced value in your saved scans", density: input.density)
    }
  }

  // MARK: Colours and legend

  private func layerColors(model: OverTimeModel, style: HistoryChartStyle) -> [String: AtlasRGB] {
    var colors = style.distinctColors(
      grouping: model.series.grouping,
      keys: model.namedLayers.map { (key: $0.id, label: $0.label) })
    colors[StackedSeries.otherLayerID] = tokens.palette.ink3.mixed(
      with: tokens.palette.surface, amount: 0.4)
    return colors
  }

  private func legendItems(model: OverTimeModel, colors: [String: AtlasRGB]) -> [HistoryLegendItem] {
    var items = model.series.layers.reversed().map { layer in
      HistoryLegendItem(
        id: layer.id, label: layer.label, color: (colors[layer.id] ?? tokens.palette.ink3).color)
    }
    if model.hasBreaks {
      items.append(
        HistoryLegendItem(
          id: "sources-changed", label: "Sources changed", color: tokens.color(.ink3).opacity(0.5)))
    }
    return items
  }

  // MARK: Geometry

  private struct Plot {
    var rect: CGRect
    var maximum: Double
    var step: Double
    var start: TimeInterval
    var span: TimeInterval
    var count: Int
    var dates: [Date]

    func x(index: Int) -> CGFloat {
      if span > 0 {
        return rect.minX + rect.width * CGFloat((dates[index].timeIntervalSince1970 - start) / span)
      }
      return rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, count - 1))
    }

    func y(_ value: Double) -> CGFloat {
      guard maximum > 0 else { return rect.maxY }
      return rect.maxY - rect.height * CGFloat(min(max(value / maximum, 0), 1))
    }
  }

  private func plot(model: OverTimeModel, size: CGSize) -> Plot {
    let left: CGFloat = (isCompact ? 34 : 46) * textScale
    let bottom: CGFloat = (isCompact ? 18 : 24) * textScale
    let rect = CGRect(
      x: left, y: 6, width: max(10, size.width - left - 8),
      height: max(10, size.height - bottom - 6))
    let dates = model.series.dates
    let start = dates.first?.timeIntervalSince1970 ?? 0
    let end = dates.last?.timeIntervalSince1970 ?? start
    let axis = HistoryChartMath.axis(
      maximum: model.maximumTotal * 1.02, intervals: isCompact ? 2 : 4)
    return Plot(
      rect: rect, maximum: axis.top, step: axis.step, start: start, span: end - start,
      count: model.count, dates: dates)
  }

  // MARK: Chart

  @ViewBuilder
  private func chart(
    model: OverTimeModel, colors: [String: AtlasRGB], style: HistoryChartStyle, size: CGSize
  ) -> some View {
    let plot = plot(model: model, size: size)
    let hovered = active
    let timeZone = input.timeZone
    let onSelect = input.onSelect
    Canvas { context, canvasSize in
      draw(
        &context, size: canvasSize, model: model, colors: colors, style: style, plot: plot,
        hovered: hovered, timeZone: timeZone)
    }
    .historyPointer(
      active: $active,
      hitTest: { point in hit(point, plot: plot) },
      onActivate: { index in
        if model.series.runIDs.indices.contains(index) {
          onSelect(.run(model.series.runIDs[index]))
        }
      }
    )
    .accessibilityChildren {
      ForEach(model.series.runIDs.indices, id: \.self) { index in
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(
            model.tooltipLines(at: index, timeZone: timeZone).joined(separator: ", "))
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { onSelect(.run(model.series.runIDs[index])) }
      }
    }
    .historyAccessibility(
      label: model.summary(timeZone: timeZone, grouping: model.series.grouping))
  }

  private func hit(_ point: CGPoint, plot: Plot) -> Int? {
    guard point.x >= plot.rect.minX - 8, point.x <= plot.rect.maxX + 8,
      point.y >= plot.rect.minY - 4, point.y <= plot.rect.maxY + 4, plot.count > 0
    else { return nil }
    var best = 0
    var distance = CGFloat.infinity
    for index in 0..<plot.count {
      let current = abs(plot.x(index: index) - point.x)
      if current < distance {
        distance = current
        best = index
      }
    }
    return best
  }

  // MARK: Drawing

  private func draw(
    _ context: inout GraphicsContext,
    size: CGSize,
    model: OverTimeModel,
    colors: [String: AtlasRGB],
    style: HistoryChartStyle,
    plot: Plot,
    hovered: Int?,
    timeZone: TimeZone
  ) {
    drawAxes(&context, model: model, style: style, plot: plot, timeZone: timeZone)
    drawGaps(&context, model: model, style: style, plot: plot)
    drawLayers(&context, model: model, colors: colors, style: style, plot: plot)
    if let hovered, model.series.dates.indices.contains(hovered) {
      let x = plot.x(index: hovered)
      var guide = Path()
      guide.move(to: CGPoint(x: x, y: plot.rect.minY))
      guide.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
      context.stroke(guide, with: .color(style.ink), lineWidth: 1)
      let top = CGPoint(x: x, y: plot.y(model.series.totals[hovered]))
      let dot = Path(ellipseIn: CGRect(x: top.x - 3.5, y: top.y - 3.5, width: 7, height: 7))
      context.fill(dot, with: .color(style.ink))
      context.stroke(dot, with: .color(style.surface), lineWidth: 1.5)
      HistoryTooltip(lines: model.tooltipLines(at: hovered, timeZone: timeZone), anchor: top)
        .draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
    }
  }

  private func drawAxes(
    _ context: inout GraphicsContext, model: OverTimeModel, style: HistoryChartStyle, plot: Plot,
    timeZone: TimeZone
  ) {
    let tickCount = max(1, Int((plot.maximum / plot.step).rounded()))
    for value in HistoryChartMath.ticks(maximum: plot.maximum, count: tickCount) {
      let y = plot.y(value)
      var line = Path()
      line.move(to: CGPoint(x: plot.rect.minX, y: y))
      line.addLine(to: CGPoint(x: plot.rect.maxX, y: y))
      context.stroke(
        line, with: .color(value == 0 ? style.rule : style.ruleSoft),
        lineWidth: value == 0 ? 1 : 0.75)
      context.historyDraw(
        HistoryChartFormat.usdCompact(value), font: style.smallFigureFont, color: style.ink3,
        at: CGPoint(x: plot.rect.minX - 6, y: y), anchor: .trailing)
    }
    // Date labels: as many as fit without touching.
    let dates = model.series.dates
    guard let first = dates.first, let last = dates.last else { return }
    let sample = context.historyMeasure("28 Mmm", font: style.smallFigureFont).width
    let count = max(2, min(6, Int(plot.rect.width / (sample + 22))))
    var lastEnd = -CGFloat.infinity
    for step in 0..<count {
      let fraction = Double(step) / Double(count - 1)
      let date = first.addingTimeInterval(last.timeIntervalSince(first) * fraction)
      let x = plot.rect.minX + plot.rect.width * CGFloat(fraction)
      let anchor: UnitPoint = step == 0 ? .topLeading : (step == count - 1 ? .topTrailing : .top)
      let rect = context.historyMeasure(
        HistoryChartFormat.day(date, timeZone: timeZone), font: style.smallFigureFont)
      let originX = x - rect.width * anchor.x
      guard originX >= lastEnd + 8 else { continue }
      context.historyDraw(
        HistoryChartFormat.day(date, timeZone: timeZone), font: style.smallFigureFont,
        color: style.ink3, at: CGPoint(x: x, y: plot.rect.maxY + 6), anchor: anchor)
      lastEnd = originX + rect.width
    }
  }

  /// The space between two scans that did not read the same sources: shaded,
  /// with a dashed rule and a marker, and no area drawn across it.
  private func drawGaps(
    _ context: inout GraphicsContext, model: OverTimeModel, style: HistoryChartStyle, plot: Plot
  ) {
    for (index, isBreak) in model.breaks.enumerated() where isBreak {
      let left = plot.x(index: index)
      let right = plot.x(index: index + 1)
      let band = CGRect(
        x: min(left, right), y: plot.rect.minY, width: max(abs(right - left), 1),
        height: plot.rect.height)
      context.fill(Path(band), with: .color(style.ink3.opacity(0.12)))
      let middle = (left + right) / 2
      var rule = Path()
      rule.move(to: CGPoint(x: middle, y: plot.rect.minY))
      rule.addLine(to: CGPoint(x: middle, y: plot.rect.maxY))
      context.stroke(
        rule, with: .color(style.ink2),
        style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
      let marker = Path(
        ellipseIn: CGRect(x: middle - 4, y: plot.rect.minY - 4, width: 8, height: 8))
      context.fill(marker, with: .color(style.surface))
      context.stroke(marker, with: .color(style.ink2), lineWidth: 1.5)
    }
  }

  private func drawLayers(
    _ context: inout GraphicsContext, model: OverTimeModel, colors: [String: AtlasRGB],
    style: HistoryChartStyle, plot: Plot
  ) {
    let edges = model.edges
    let layers = model.series.layers
    let lineWidth = max(1, style.markBorderWidth * 0.6)
    let separator = style.markBorderWidth > 0 ? style.ink : style.surface
    for segment in model.segments {
      for (layerIndex, layer) in layers.enumerated() {
        let color = (colors[layer.id] ?? tokens.palette.ink3).color
        var area = Path()
        if segment.lowerBound == segment.upperBound {
          // A lone scan between two breaks: a narrow column.
          let x = plot.x(index: segment.lowerBound)
          let top = plot.y(edges[layerIndex][segment.lowerBound])
          let bottom = plot.y(layerIndex == 0 ? 0 : edges[layerIndex - 1][segment.lowerBound])
          area.addRect(CGRect(x: x - 2, y: top, width: 4, height: max(0, bottom - top)))
          context.fill(area, with: .color(color))
          continue
        }
        for index in segment {
          let point = CGPoint(x: plot.x(index: index), y: plot.y(edges[layerIndex][index]))
          if index == segment.lowerBound { area.move(to: point) } else { area.addLine(to: point) }
        }
        let topEdge = area
        for index in segment.reversed() {
          let base = layerIndex == 0 ? 0 : edges[layerIndex - 1][index]
          area.addLine(to: CGPoint(x: plot.x(index: index), y: plot.y(base)))
        }
        area.closeSubpath()
        context.fill(area, with: .color(color))
        context.stroke(topEdge, with: .color(separator), lineWidth: lineWidth)
      }
    }
  }
}
