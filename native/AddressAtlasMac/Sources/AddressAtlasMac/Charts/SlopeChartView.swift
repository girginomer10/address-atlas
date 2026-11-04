import AddressAtlasCore
import SwiftUI

/// How each coin's rank by value moved between an earlier scan and the latest:
/// one line per coin from its rank then (left) to its rank now (right), in the
/// coin's colour, with the places gained or lost at the right-hand end. Coins
/// that entered or left the ranking sit below a divider as "new" or "out".
///
/// The earlier scan is the oldest one from the last 30 days that read the same
/// sources as the latest, else the scan before it. When the two scans read
/// different sources the chart says so, because some moves are then a wallet
/// appearing. Hover (Mac) or tap (iOS) shows a coin's ranks and values; clicking
/// or tapping reports `.coin(key)`.
struct SlopeChartView: View {
  let input: PortfolioChartInput
  private let pair: (older: ScanRunRecord, newer: ScanRunRecord)?

  @Environment(\.atlasTheme) private var tokens
  @ScaledMetric(relativeTo: .caption) private var textScale: CGFloat = 1
  @State private var active: String?
  @State private var cache = HistoryLayoutCache<SlopeKey, SlopeModel>()

  struct SlopeKey: Equatable {
    var width: Int
    var height: Int
    var compact: Bool
  }

  init(input: PortfolioChartInput) {
    self.input = input
    pair = SlopeModel.choosePair(runs: input.runs, context: input.sourceContext)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    if pair == nil {
      HistoryChartMessage(
        title: "Not enough scans yet",
        detail: "Save another scan to compare how coins rank.", density: input.density)
    } else if let pair, PortfolioAnalytics.totalValueUsd(pair.newer.holdings) <= 0 {
      HistoryChartMessage(title: "No priced holdings to rank", density: input.density)
    } else if let pair {
      let style = HistoryChartStyle(tokens: tokens, density: input.density)
      VStack(alignment: .leading, spacing: 6) {
        GeometryReader { proxy in
          chart(pair: pair, style: style, size: proxy.size)
        }
        notes(pair: pair, style: style)
      }
    }
  }

  // MARK: Notes

  @ViewBuilder
  private func notes(pair: (older: ScanRunRecord, newer: ScanRunRecord), style: HistoryChartStyle)
    -> some View
  {
    let sourcesDiffer = !PortfolioAnalytics.runsShareSources(
      pair.older, pair.newer, context: input.sourceContext)
    VStack(alignment: .leading, spacing: 2) {
      if sourcesDiffer {
        Text(verbatim: "These scans read different sources, so some moves are not market moves.")
          .font(style.smallFont)
          .foregroundStyle(style.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !isCompact {
        Text(verbatim: "new: not ranked in the earlier scan. out: not ranked in the latest scan.")
          .font(style.smallFont)
          .foregroundStyle(style.ink3)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }

  // MARK: Layout

  private struct Plot {
    var rect: CGRect
    var leftX: CGFloat
    var rightX: CGFloat
    var rowHeight: CGFloat
    var slotCount: Int

    func y(slot: Int) -> CGFloat { rect.minY + rowHeight * (CGFloat(slot) + 0.5) }
  }

  private func plot(model: SlopeModel, size: CGSize) -> Plot {
    let header: CGFloat = (isCompact ? 16 : 22) * textScale
    let gutter = min(size.width * (isCompact ? 0.3 : 0.27), 150 * textScale)
    let rect = CGRect(
      x: 4, y: header, width: max(10, size.width - 8), height: max(10, size.height - header - 2))
    let slots = max(1, model.slotCount)
    return Plot(
      rect: rect, leftX: rect.minX + gutter, rightX: rect.maxX - gutter,
      rowHeight: rect.height / CGFloat(slots), slotCount: slots)
  }

  private func model(pair: (older: ScanRunRecord, newer: ScanRunRecord), size: CGSize) -> SlopeModel
  {
    let header: CGFloat = (isCompact ? 16 : 22) * textScale
    let minimumRow: CGFloat = (isCompact ? 15 : 21) * textScale
    let slots = max(4, Int((size.height - header) / minimumRow))
    let key = SlopeKey(width: Int(size.width), height: Int(size.height), compact: isCompact)
    return cache.value(for: key) {
      SlopeModel.make(
        older: pair.older, newer: pair.newer, context: input.sourceContext,
        desiredLimit: isCompact ? 5 : 8, maximumSlots: slots)
    }
  }

  // MARK: Chart

  @ViewBuilder
  private func chart(
    pair: (older: ScanRunRecord, newer: ScanRunRecord), style: HistoryChartStyle, size: CGSize
  ) -> some View {
    let model = model(pair: pair, size: size)
    let plot = plot(model: model, size: size)
    let colors = style.distinctColors(
      grouping: .asset, keys: model.rows.map { (key: $0.id, label: $0.symbol) })
    let hovered = active
    let timeZone = input.timeZone
    let onSelect = input.onSelect
    Canvas { context, canvasSize in
      draw(
        &context, size: canvasSize, model: model, style: style, plot: plot, colors: colors,
        hovered: hovered, timeZone: timeZone)
    }
    .historyPointer(
      active: $active,
      hitTest: { point in hit(point, model: model, plot: plot) },
      onActivate: { key in onSelect(.coin(key)) }
    )
    .accessibilityChildren {
      ForEach(model.rows) { row in
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(model.accessibilityLabel(for: row))
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { onSelect(.coin(row.id)) }
      }
    }
    .historyAccessibility(label: model.summary(timeZone: timeZone))
  }

  private func curveY(row: SlopeModel.Row, plot: Plot, at t: CGFloat) -> CGFloat {
    let from = plot.y(slot: row.leftSlot)
    let to = plot.y(slot: row.rightSlot)
    let s = 3 * t * t - 2 * t * t * t
    return from * (1 - s) + to * s
  }

  private func hit(_ point: CGPoint, model: SlopeModel, plot: Plot) -> String? {
    guard plot.rect.insetBy(dx: 0, dy: -4).contains(point) else { return nil }
    if point.x <= plot.leftX {
      return model.rows.first { abs(plot.y(slot: $0.leftSlot) - point.y) <= plot.rowHeight / 2 }?.id
    }
    if point.x >= plot.rightX {
      return model.rows.first { abs(plot.y(slot: $0.rightSlot) - point.y) <= plot.rowHeight / 2 }?.id
    }
    // Between the columns: the line nearest the pointer, if close enough.
    let t = (point.x - plot.leftX) / max(1, plot.rightX - plot.leftX)
    var best: (id: String, distance: CGFloat)?
    for row in model.rows {
      let distance = abs(curveY(row: row, plot: plot, at: t) - point.y)
      if distance <= max(8, plot.rowHeight / 2), distance < (best?.distance ?? .infinity) {
        best = (row.id, distance)
      }
    }
    return best?.id
  }

  // MARK: Drawing

  private func draw(
    _ context: inout GraphicsContext,
    size: CGSize,
    model: SlopeModel,
    style: HistoryChartStyle,
    plot: Plot,
    colors: [String: AtlasRGB],
    hovered: String?,
    timeZone: TimeZone
  ) {
    // Column axes and dates.
    for x in [plot.leftX, plot.rightX] {
      var axis = Path()
      axis.move(to: CGPoint(x: x, y: plot.rect.minY))
      axis.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
      context.stroke(axis, with: .color(style.ruleSoft), lineWidth: 1)
    }
    let headerY = plot.rect.minY - 5
    context.historyDraw(
      HistoryChartFormat.day(model.olderDate, timeZone: timeZone), font: style.captionFigureFont,
      color: style.ink2, at: CGPoint(x: plot.leftX, y: headerY), anchor: .bottom)
    context.historyDraw(
      HistoryChartFormat.day(model.newerDate, timeZone: timeZone), font: style.captionFigureFont,
      color: style.ink2, at: CGPoint(x: plot.rightX, y: headerY), anchor: .bottom)

    // The divider above the coins that sit outside the ranked rows.
    if model.slotCount > model.rankedSlots {
      let y = plot.y(slot: model.rankedSlots)
      let caption = context.historyDraw(
        "Outside the top \(model.rankedSlots)", font: style.smallFigureFont, color: style.ink3,
        at: CGPoint(x: plot.rect.minX + 2, y: y), anchor: .leading)
      var divider = Path()
      divider.move(to: CGPoint(x: caption.maxX + 8, y: y))
      divider.addLine(to: CGPoint(x: plot.rect.maxX, y: y))
      context.stroke(
        divider, with: .color(style.ruleSoft), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    // Lines: the pointed-at coin last, so it is on top.
    let ordered = model.rows.sorted { lhs, rhs in
      if (lhs.id == hovered) != (rhs.id == hovered) { return rhs.id == hovered }
      return lhs.id < rhs.id
    }
    let lineWidth: CGFloat = isCompact ? 2 : 2.75
    for row in ordered {
      let color = (colors[row.id] ?? tokens.palette.ink3).color
      let dimmed = hovered != nil && hovered != row.id
      let from = CGPoint(x: plot.leftX, y: plot.y(slot: row.leftSlot))
      let to = CGPoint(x: plot.rightX, y: plot.y(slot: row.rightSlot))
      let middle = (from.x + to.x) / 2
      var line = Path()
      line.move(to: from)
      line.addCurve(
        to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
      let unranked = row.leftOutside || row.rightOutside
      context.stroke(
        line, with: .color(color.opacity(dimmed ? 0.28 : 1)),
        style: StrokeStyle(
          lineWidth: lineWidth, lineCap: .round, dash: unranked ? [5, 4] : []))
      dot(&context, at: from, color: color, hollow: row.leftOutside, dimmed: dimmed, style: style)
      dot(&context, at: to, color: color, hollow: row.rightOutside, dimmed: dimmed, style: style)
      labels(&context, row: row, from: from, to: to, style: style, plot: plot, dimmed: dimmed)
    }

    if let hovered, let row = model.rows.first(where: { $0.id == hovered }) {
      HistoryTooltip(
        lines: model.tooltipLines(for: row),
        anchor: CGPoint(x: plot.rightX, y: plot.y(slot: row.rightSlot))
      ).draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
    }
  }

  private func dot(
    _ context: inout GraphicsContext, at point: CGPoint, color: Color, hollow: Bool, dimmed: Bool,
    style: HistoryChartStyle
  ) {
    let radius: CGFloat = isCompact ? 3.5 : 4.5
    let shape = Path(
      ellipseIn: CGRect(
        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    context.fill(shape, with: .color(hollow ? style.surface : color.opacity(dimmed ? 0.28 : 1)))
    context.stroke(shape, with: .color(color.opacity(dimmed ? 0.28 : 1)), lineWidth: 1.75)
  }

  private func labels(
    _ context: inout GraphicsContext, row: SlopeModel.Row, from: CGPoint, to: CGPoint,
    style: HistoryChartStyle, plot: Plot, dimmed: Bool
  ) {
    let strong = style.strongFont
    let small = style.captionFigureFont
    let ink = dimmed ? style.ink3 : style.ink
    let faint = style.ink3
    let gutter = plot.leftX - plot.rect.minX
    // Left: rank, then the coin, right-aligned against the dot.
    let leftSymbol = context.historyFit(
      row.symbol, font: strong, maxWidth: gutter - 14, minimumCharacters: 2)
    if let leftSymbol {
      let symbolRect = context.historyDraw(
        leftSymbol, font: strong, color: ink, at: CGPoint(x: from.x - 10, y: from.y),
        anchor: .trailing)
      let tag: String
      if let rank = row.olderRank, !row.leftOutside {
        tag = "\(rank)"
      } else if let rank = row.olderRank {
        tag = "#\(rank)"
      } else {
        tag = "new"
      }
      if symbolRect.minX - 6 > plot.rect.minX {
        context.historyDraw(
          tag, font: small, color: faint, at: CGPoint(x: symbolRect.minX - 6, y: from.y),
          anchor: .trailing)
      }
    }
    // Right: the coin, its rank, and the move.
    let rightRoom = plot.rect.maxX - to.x - 10
    if let rightSymbol = context.historyFit(
      row.symbol, font: strong, maxWidth: rightRoom * 0.6, minimumCharacters: 2)
    {
      let symbolRect = context.historyDraw(
        rightSymbol, font: strong, color: ink, at: CGPoint(x: to.x + 10, y: to.y),
        anchor: .leading)
      var cursor = symbolRect.maxX + 6
      if let rank = row.newerRank {
        let tag = row.rightOutside ? "#\(rank)" : "\(rank)"
        let rect = context.historyDraw(
          tag, font: small, color: faint, at: CGPoint(x: cursor, y: to.y), anchor: .leading)
        cursor = rect.maxX + 6
      }
      let movement = SlopeModel.movement(row)
      if !movement.isEmpty, cursor + 14 < plot.rect.maxX {
        let tint: Color
        if row.isNew || row.isGone {
          tint = faint
        } else if let gained = row.placesGained {
          tint = gained > 0 ? style.gain : (gained < 0 ? style.loss : faint)
        } else {
          tint = faint
        }
        context.historyDraw(
          movement, font: small, color: dimmed ? faint : tint,
          at: CGPoint(x: cursor, y: to.y), anchor: .leading)
      }
    }
  }
}
