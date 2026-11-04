import AddressAtlasCore
import SwiftUI

/// One coin's amount over the saved scans, in coins rather than dollars, so
/// price moves cannot hide what you did. Stacked by state (liquid, staked,
/// unbonding, rewards, on exchange), with a label where you unstaked,
/// unlocked, received or sent. Where two neighbouring scans did not read the
/// same wallets and exchanges, the chart is cut and a dashed rule marks it,
/// so a new wallet is never mistaken for received coins.
///
/// Coin widgets take `input.coinKey` (a `CoinIdentity.key`) and, when it is
/// nil, the largest coin in `input.holdings`. Hover (Mac) or tap (iOS) shows
/// the amounts of the nearest scan; clicking or tapping reports `.run(id)`.
struct CoinAmountHistoryView: View {
  let input: PortfolioChartInput

  @Environment(\.atlasTheme) private var tokens
  @State private var hovered: String?

  init(input: PortfolioChartInput) {
    self.input = input
  }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let compact = input.density == .compact
    if let key = CoinWidgetResolver.coinKey(for: input) {
      if input.runs.count < 2 {
        HistoryChartMessage(
          title: "Save another scan to see this coin over time.", density: input.density)
      } else if let model = CoinAmountHistoryModel.make(
        runs: input.runs, coinKey: key, context: input.sourceContext,
        maximumAnnotations: compact ? 1 : 3)
      {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
          chart(model: model, style: style)
          legend(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .historyAccessibility(label: model.spokenSummary(timeZone: input.timeZone))
      } else {
        HistoryChartMessage(
          title: "No \(key) in your saved scans.", density: input.density)
      }
    } else {
      HistoryChartMessage(title: "No holdings to show.", density: input.density)
    }
  }

  // MARK: Legend

  private func legend(model: CoinAmountHistoryModel) -> some View {
    var items = model.layers.reversed().map { layer in
      HistoryLegendItem(
        id: layer.id, label: layer.state.displayName,
        color: CoinWidgetResolver.stateColor(layer.state, tokens: tokens).color)
    }
    if model.hasSourceChange {
      items.append(
        HistoryLegendItem(
          id: "sources-changed", label: "Sources changed",
          color: tokens.color(.ink3).opacity(0.7)))
    }
    return HistoryLegend(items: items, density: input.density)
  }

  // MARK: Geometry

  private struct Geometry {
    var plot: CGRect
    var domainMaximum: Double
    var ticks: [Double]
    var startTime: TimeInterval
    var spanTime: TimeInterval

    func x(_ date: Date) -> CGFloat {
      guard spanTime > 0 else { return plot.minX }
      return plot.minX + plot.width * CGFloat((date.timeIntervalSince1970 - startTime) / spanTime)
    }

    func y(_ amount: Double) -> CGFloat {
      guard domainMaximum > 0 else { return plot.maxY }
      return plot.maxY - plot.height * CGFloat(min(max(amount / domainMaximum, 0), 1))
    }
  }

  private func geometry(size: CGSize, model: CoinAmountHistoryModel, labelRows: Int) -> Geometry {
    let compact = input.density == .compact
    let gutter: CGFloat = compact ? 26 : 38
    let plot = CGRect(
      x: gutter, y: 4, width: max(10, size.width - gutter - 8),
      height: max(10, size.height - (compact ? 20 : 26)))
    let rowHeight: CGFloat = compact ? 13 : 16
    let headroom = labelRows > 0 ? min(0.4, (CGFloat(labelRows) * rowHeight + 6) / plot.height) : 0.06
    let maximum = max(model.maximumTotal, 1e-9)
    let rawDomain = maximum / Double(1 - headroom)
    let step = Self.niceStep(rawDomain / Double(compact ? 3 : 4))
    var ticks: [Double] = []
    var value = 0.0
    while value <= rawDomain + step * 0.001 && ticks.count < 12 {
      ticks.append(value)
      value += step
    }
    let start = model.dates.first?.timeIntervalSince1970 ?? 0
    let end = model.dates.last?.timeIntervalSince1970 ?? start
    return Geometry(
      plot: plot, domainMaximum: max(rawDomain, step), ticks: ticks, startTime: start,
      spanTime: end - start)
  }

  static func niceStep(_ raw: Double) -> Double {
    guard raw.isFinite, raw > 0 else { return 1 }
    let exponent = floor(log10(raw))
    let base = pow(10, exponent)
    let fraction = raw / base
    let nice: Double
    switch fraction {
    case ...1: nice = 1
    case ...2: nice = 2
    case ...5: nice = 5
    default: nice = 10
    }
    return nice * base
  }

  // MARK: Chart

  private func chart(model: CoinAmountHistoryModel, style: HistoryChartStyle) -> some View {
    let compact = input.density == .compact
    let labelRows = min(model.annotations.count, compact ? 1 : 2)
    let hoveredID = hovered
    return GeometryReader { proxy in
      let size = proxy.size
      let geo = geometry(size: size, model: model, labelRows: labelRows)
      Canvas { context, size in
        draw(
          context: &context, size: size, model: model, geo: geo, style: style, hovered: hoveredID)
      }
      .contentShape(Rectangle())
      .historyPointer(
        active: $hovered,
        hitTest: { point in hit(point, model: model, geo: geo) },
        onActivate: { id in
          if let index = Self.runIndex(of: id), model.runIDs.indices.contains(index) {
            input.onSelect(.run(model.runIDs[index]))
          }
        }
      )
      .accessibilityChildren {
        ForEach(Array(model.runIDs.enumerated()), id: \.offset) { index, runID in
          Color.clear
            .accessibilityLabel(
              annotatedTooltip(model: model, index: index).joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { input.onSelect(.run(runID)) }
        }
      }
    }
    .frame(minHeight: compact ? 80 : 160)
  }

  private static func id(run index: Int) -> String { "run-\(index)" }
  private static func id(gap index: Int) -> String { "gap-\(index)" }
  private static func runIndex(of id: String) -> Int? {
    id.hasPrefix("run-") ? Int(id.dropFirst(4)) : nil
  }
  private static func gapIndex(of id: String) -> Int? {
    id.hasPrefix("gap-") ? Int(id.dropFirst(4)) : nil
  }

  private func hit(_ point: CGPoint, model: CoinAmountHistoryModel, geo: Geometry) -> String? {
    guard point.x >= geo.plot.minX - 4, point.x <= geo.plot.maxX + 4,
      point.y >= geo.plot.minY - 4, point.y <= geo.plot.maxY + 4
    else { return nil }
    for (index, isBreak) in model.sourceBreaks.enumerated() where isBreak {
      let gapX = (geo.x(model.dates[index]) + geo.x(model.dates[index + 1])) / 2
      if abs(point.x - gapX) <= 4 { return Self.id(gap: index) }
    }
    var best = 0
    var distance = CGFloat.infinity
    for index in model.dates.indices {
      let current = abs(geo.x(model.dates[index]) - point.x)
      if current < distance {
        distance = current
        best = index
      }
    }
    return Self.id(run: best)
  }

  private func annotatedTooltip(model: CoinAmountHistoryModel, index: Int) -> [String] {
    var lines = model.tooltipLines(at: index, timeZone: input.timeZone)
    for annotation in model.annotations where annotation.runIndex == index {
      lines.insert(annotation.text, at: 1)
    }
    return lines
  }

  private func draw(
    context: inout GraphicsContext,
    size: CGSize,
    model: CoinAmountHistoryModel,
    geo: Geometry,
    style: HistoryChartStyle,
    hovered: String?
  ) {
    let compact = input.density == .compact
    let plot = geo.plot
    let axisFont = style.smallFont

    // Gridlines and amount labels.
    for tick in geo.ticks {
      let y = geo.y(tick)
      var line = Path()
      line.move(to: CGPoint(x: plot.minX, y: y))
      line.addLine(to: CGPoint(x: plot.maxX, y: y))
      context.stroke(
        line, with: .color(tick == 0 ? style.rule : style.ruleSoft),
        style: StrokeStyle(lineWidth: tick == 0 ? 1 : 0.75, dash: tick == 0 ? [] : [2, 3]))
      let text = HistoryChartFormat.amount(tick)
      if let fitted = context.historyFit(text, font: axisFont, maxWidth: plot.minX - 6) {
        context.historyDraw(
          fitted, font: axisFont, color: style.ink3, at: CGPoint(x: plot.minX - 5, y: y),
          anchor: UnitPoint(x: 1, y: 0.5))
      }
    }

    // Stacked areas, one block per run of joinable scans.
    var cumulative: [[Double]] = []
    var running = [Double](repeating: 0, count: model.runCount)
    for layer in model.layers {
      for index in 0..<model.runCount { running[index] += layer.values[index] }
      cumulative.append(running)
    }
    for segment in model.segments {
      for (layerIndex, layer) in model.layers.enumerated() {
        let color = CoinWidgetResolver.stateColor(layer.state, tokens: tokens).color
        let top = cumulative[layerIndex]
        let bottom = layerIndex == 0 ? [Double](repeating: 0, count: model.runCount) : cumulative[layerIndex - 1]
        if segment.count == 1, let index = segment.first {
          // A single scan between two source changes: a thin column.
          let x = geo.x(model.dates[index])
          let rect = CGRect(
            x: x - 1.5, y: geo.y(top[index]), width: 3,
            height: max(0, geo.y(bottom[index]) - geo.y(top[index])))
          context.fill(Path(rect), with: .color(color))
          continue
        }
        var path = Path()
        for index in segment {
          let point = CGPoint(x: geo.x(model.dates[index]), y: geo.y(top[index]))
          if index == segment.lowerBound { path.move(to: point) } else { path.addLine(to: point) }
        }
        for index in segment.reversed() {
          path.addLine(to: CGPoint(x: geo.x(model.dates[index]), y: geo.y(bottom[index])))
        }
        path.closeSubpath()
        context.fill(path, with: .color(color))
        // A thin separator between layers keeps neighbours apart in any theme.
        var edge = Path()
        for index in segment {
          let point = CGPoint(x: geo.x(model.dates[index]), y: geo.y(top[index]))
          if index == segment.lowerBound { edge.move(to: point) } else { edge.addLine(to: point) }
        }
        let isTop = layerIndex == model.layers.count - 1
        context.stroke(
          edge, with: .color(isTop && style.markBorderWidth > 0 ? style.outline : style.surface),
          lineWidth: isTop && style.markBorderWidth > 0 ? style.markBorderWidth : 1.2)
      }
    }

    // Source changes: a dashed rule between the two scans.
    for (index, isBreak) in model.sourceBreaks.enumerated() where isBreak {
      let x = (geo.x(model.dates[index]) + geo.x(model.dates[index + 1])) / 2
      var rule = Path()
      rule.move(to: CGPoint(x: x, y: plot.minY))
      rule.addLine(to: CGPoint(x: x, y: plot.maxY))
      context.stroke(
        rule, with: .color(style.ink3),
        style: StrokeStyle(lineWidth: hovered == Self.id(gap: index) ? 2 : 1.25, dash: [4, 3]))
    }

    // What you did: a dashed rule and a label in the free band at the top.
    var labelRects: [CGRect] = []
    let rowHeight: CGFloat = compact ? 13 : 16
    for (order, annotation) in model.annotations.enumerated() {
      let x = geo.x(model.dates[annotation.runIndex])
      var rule = Path()
      rule.move(to: CGPoint(x: x, y: plot.minY))
      rule.addLine(to: CGPoint(x: x, y: plot.maxY))
      context.stroke(
        rule, with: .color(style.ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
      let font = style.captionFont
      let size = context.historyMeasure(annotation.text, font: font)
      let row = order % 2
      let rightSide = x + 6 + size.width <= plot.maxX
      let originX = rightSide ? x + 6 : x - 6 - size.width
      let rect = CGRect(x: originX, y: plot.minY + CGFloat(row) * rowHeight, width: size.width, height: size.height)
      if !labelRects.contains(where: { $0.insetBy(dx: -4, dy: -1).intersects(rect) }) {
        labelRects.append(rect)
        // A chip behind the text keeps the dashed rules from cutting through it.
        let chip = rect.insetBy(dx: -3, dy: -1)
        context.fill(
          RoundedRectangle(cornerRadius: 3, style: .continuous).path(in: chip),
          with: .color(style.surface))
        context.historyDraw(
          annotation.text, font: font, color: style.ink, at: CGPoint(x: rect.minX, y: rect.minY),
          anchor: .topLeading)
      }
    }

    // Date labels.
    var dateRects: [CGRect] = []
    let datesY = plot.maxY + 5
    func dateLabel(_ index: Int, anchorX: CGFloat) {
      let text = HistoryChartFormat.day(model.dates[index], timeZone: input.timeZone)
      let size = context.historyMeasure(text, font: axisFont)
      let x = geo.x(model.dates[index])
      var originX = x - size.width * anchorX
      originX = min(max(originX, 0), max(0, plot.maxX + 8 - size.width))
      let rect = CGRect(x: originX, y: datesY, width: size.width, height: size.height)
      if dateRects.contains(where: { $0.insetBy(dx: -8, dy: 0).intersects(rect) }) { return }
      dateRects.append(rect)
      context.historyDraw(
        text, font: axisFont, color: style.ink3, at: CGPoint(x: rect.minX, y: rect.minY),
        anchor: .topLeading)
    }
    if let last = model.dates.indices.last {
      dateLabel(0, anchorX: 0)
      dateLabel(last, anchorX: 1)
      if !compact, last >= 2 {
        // A label in the middle of the time span, if it has room.
        let mid = geo.startTime + geo.spanTime / 2
        let nearest = model.dates.indices.min {
          abs(model.dates[$0].timeIntervalSince1970 - mid) < abs(model.dates[$1].timeIntervalSince1970 - mid)
        }
        if let nearest { dateLabel(nearest, anchorX: 0.5) }
      }
    }

    // Hover: a rule on the nearest scan and the numbers for it.
    if let hovered {
      if let index = Self.runIndex(of: hovered), model.dates.indices.contains(index) {
        let x = geo.x(model.dates[index])
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: plot.minY))
        rule.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(rule, with: .color(style.ink), lineWidth: 1.5)
        let dot = Path(
          ellipseIn: CGRect(x: x - 4, y: geo.y(model.totals[index]) - 4, width: 8, height: 8))
        context.fill(dot, with: .color(style.surface))
        context.stroke(dot, with: .color(style.ink), lineWidth: 2)
        HistoryTooltip(
          lines: annotatedTooltip(model: model, index: index),
          anchor: CGPoint(x: x, y: geo.y(model.totals[index]))
        ).draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
      } else if let gap = Self.gapIndex(of: hovered), model.sourceBreaks.indices.contains(gap) {
        let x = (geo.x(model.dates[gap]) + geo.x(model.dates[gap + 1])) / 2
        HistoryTooltip(
          lines: ["Sources changed", "These two scans did not read the same wallets and exchanges."],
          anchor: CGPoint(x: x, y: plot.midY)
        ).draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
      }
    }
  }
}
