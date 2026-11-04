import AddressAtlasCore
import SwiftUI

/// A calendar of daily change: one square per day in week columns, red where
/// the portfolio lost value, green where it gained, grey where it hardly moved.
/// Days without a scan are empty outlines, not zero. A day whose scan read
/// different sources than the one before is hatched and left uncoloured, since
/// its change is not a market move.
///
/// It needs scans on at least seven different days. Hover (Mac) or tap (iOS)
/// shows a day; clicking or tapping selects it and reports `.run(id)` of that
/// day's last scan.
struct CalendarChartView: View {
  let input: PortfolioChartInput
  private let model: CalendarHeatmapModel?
  private let scanDays: Int

  @Environment(\.atlasTheme) private var tokens
  @ScaledMetric(relativeTo: .caption) private var textScale: CGFloat = 1
  @State private var hovered: String?
  @State private var selected: String?

  init(input: PortfolioChartInput) {
    self.input = input
    let points = PortfolioAnalytics.dailySeries(input.runs, timeZone: input.timeZone)
    scanDays = points.count
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = HistoryChartFormat.locale
    model = CalendarHeatmapModel.make(
      points: points, runs: input.runs, context: input.sourceContext,
      firstWeekday: calendar.firstWeekday,
      minimumWeeks: input.density == .compact ? 6 : 8,
      maximumWeeks: input.density == .compact ? 12 : 26)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    if let model {
      let style = HistoryChartStyle(tokens: tokens, density: input.density)
      let activeID = hovered ?? selected ?? model.scanCells.last?.id
      HStack(alignment: .top, spacing: isCompact ? 0 : 24) {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 10) {
          GeometryReader { proxy in
            grid(model: model, style: style, size: proxy.size, activeID: activeID)
          }
          legend(model: model, style: style)
        }
        if !isCompact {
          detail(model: model, style: style, activeID: activeID)
            .frame(width: 190, alignment: .topLeading)
        }
      }
    } else {
      HistoryChartMessage(
        title: "Scan on more days to fill the calendar.",
        detail: scanDays == 0
          ? nil : "\(scanDays) of \(CalendarHeatmapModel.minimumScanDays) days so far.",
        density: input.density)
    }
  }

  // MARK: Colours

  private func fill(for entry: CalendarHeatmapModel.Entry, model: CalendarHeatmapModel)
    -> Color
  {
    let neutral = tokens.palette.surfaceMuted
    guard let change = entry.marketChange else { return neutral.color }
    let target = change >= 0 ? tokens.palette.gain : tokens.palette.loss
    let intensity = model.intensity(of: entry)
    guard intensity > 0.02 else { return neutral.color }
    return neutral.mixed(with: target, amount: 0.22 + 0.78 * intensity).color
  }

  // MARK: Geometry

  private struct Grid {
    var origin: CGPoint
    var pitch: CGFloat
    var side: CGFloat
    var weeks: Int

    func rect(column: Int, row: Int) -> CGRect {
      CGRect(
        x: origin.x + CGFloat(column) * pitch, y: origin.y + CGFloat(row) * pitch, width: side,
        height: side)
    }
  }

  private func grid(model: CalendarHeatmapModel, size: CGSize) -> Grid {
    let leftGutter: CGFloat = (isCompact ? 0 : 30) * textScale
    let topGutter: CGFloat = (isCompact ? 14 : 20) * textScale
    let maximumPitch: CGFloat = isCompact ? 26 : 46
    let pitch = max(
      6,
      min(
        maximumPitch, (size.width - leftGutter) / CGFloat(model.weeks),
        (size.height - topGutter) / 7))
    let gap: CGFloat = isCompact ? 2 : 4
    // A compact calendar has no panel beside it, so centre it in the card.
    let centering = isCompact
      ? max(0, (size.width - leftGutter - pitch * CGFloat(model.weeks)) / 2) : 0
    return Grid(
      origin: CGPoint(x: leftGutter + centering, y: topGutter), pitch: pitch,
      side: max(3, pitch - gap), weeks: model.weeks)
  }

  // MARK: Chart

  @ViewBuilder
  private func grid(
    model: CalendarHeatmapModel, style: HistoryChartStyle, size: CGSize, activeID: String?
  ) -> some View {
    let layout = grid(model: model, size: size)
    let timeZone = input.timeZone
    let onSelect = input.onSelect
    let hoveredID = hovered
    Canvas { context, canvasSize in
      draw(
        &context, size: canvasSize, model: model, style: style, layout: layout,
        activeID: activeID, hoveredID: hoveredID, timeZone: timeZone)
    }
    .historyPointer(
      active: $hovered,
      hitTest: { point in cellID(at: point, model: model, layout: layout) },
      onActivate: { id in
        selected = id
        if let cell = model.cell(id: id), let entry = cell.entry {
          onSelect(.run(entry.point.runID))
        }
      }
    )
    .accessibilityChildren {
      ForEach(model.scanCells) { cell in
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(
            CalendarHeatmapModel.lines(for: cell, timeZone: timeZone).joined(separator: ", "))
          .accessibilityAddTraits(.isButton)
          .accessibilityAction {
            selected = cell.id
            if let entry = cell.entry { onSelect(.run(entry.point.runID)) }
          }
      }
    }
    .historyAccessibility(label: model.summary(timeZone: timeZone))
  }

  private func cellID(at point: CGPoint, model: CalendarHeatmapModel, layout: Grid) -> String? {
    let column = Int(floor((point.x - layout.origin.x) / layout.pitch))
    let row = Int(floor((point.y - layout.origin.y) / layout.pitch))
    guard column >= 0, column < model.weeks, row >= 0, row < 7 else { return nil }
    let rect = layout.rect(column: column, row: row)
    guard rect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
    return model.cells.first { $0.column == column && $0.row == row }?.id
  }

  // MARK: Drawing

  private func draw(
    _ context: inout GraphicsContext,
    size: CGSize,
    model: CalendarHeatmapModel,
    style: HistoryChartStyle,
    layout: Grid,
    activeID: String?,
    hoveredID: String?,
    timeZone: TimeZone
  ) {
    // Month names above the first column of each month.
    var lastEnd = -CGFloat.infinity
    for label in model.months {
      let x = layout.origin.x + CGFloat(label.column) * layout.pitch
      guard let month = HistoryChartFormat.monthName(label.month) else { continue }
      let width = context.historyMeasure(month, font: style.smallFont).width
      guard x >= lastEnd + 6 else { continue }
      context.historyDraw(
        month, font: style.smallFont, color: style.ink3, at: CGPoint(x: x, y: 0),
        anchor: .topLeading)
      lastEnd = x + width
    }
    // Weekday names down the left (every second row).
    if !isCompact {
      for row in [1, 3, 5] {
        let weekday = model.weekday(ofRow: row)
        let name = HistoryChartFormat.weekdayName(weekday)
        context.historyDraw(
          name, font: style.smallFont, color: style.ink3,
          at: CGPoint(
            x: layout.origin.x - 6, y: layout.origin.y + CGFloat(row) * layout.pitch + layout.side / 2),
          anchor: .trailing)
      }
    }

    let radius = style.blockRadius(for: layout.side)
    for cell in model.cells {
      let rect = layout.rect(column: cell.column, row: cell.row)
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
      guard let entry = cell.entry else {
        // No scan: an empty outline, never a zero.
        context.stroke(
          shape, with: .color(style.ruleSoft),
          style: StrokeStyle(lineWidth: 1, dash: layout.side > 10 ? [2, 2] : []))
        continue
      }
      context.fill(shape, with: .color(fill(for: entry, model: model)))
      if entry.sourcesDiffer { hatch(&context, in: rect, shape: shape, style: style) }
      if entry.point.changeUsd == nil {
        // The first scan has nothing to compare with: a small dot.
        let dot = Path(
          ellipseIn: CGRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4))
        context.fill(dot, with: .color(style.ink3))
      }
      if style.markBorderWidth > 0 {
        context.stroke(shape, with: .color(style.ink), lineWidth: style.markBorderWidth * 0.6)
      }
    }

    // The active day last, on top.
    if let activeID, let cell = model.cell(id: activeID) {
      let rect = layout.rect(column: cell.column, row: cell.row).insetBy(dx: -1.5, dy: -1.5)
      let outline = RoundedRectangle(cornerRadius: radius + 1.5, style: .continuous).path(in: rect)
      context.stroke(outline, with: .color(style.ink), lineWidth: 2)
    }
    // The wide layout has a detail panel that follows the pointer; the compact
    // one has no room for it, so it shows a tooltip.
    if isCompact, let hoveredID, let cell = model.cell(id: hoveredID) {
      let rect = layout.rect(column: cell.column, row: cell.row)
      HistoryTooltip(
        lines: CalendarHeatmapModel.lines(for: cell, timeZone: timeZone),
        anchor: CGPoint(x: rect.midX, y: rect.minY)
      ).draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
    }
  }

  private func hatch(
    _ context: inout GraphicsContext, in rect: CGRect, shape: Path, style: HistoryChartStyle
  ) {
    var inner = context
    inner.clip(to: shape)
    var lines = Path()
    var offset = -rect.height
    while offset < rect.width {
      lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
      lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
      offset += 5
    }
    inner.stroke(lines, with: .color(style.ink3.opacity(0.7)), lineWidth: 1)
  }

  // MARK: Legend and detail

  private func legend(model: CalendarHeatmapModel, style: HistoryChartStyle) -> some View {
    let loss = tokens.palette.surfaceMuted.mixed(with: tokens.palette.loss, amount: 1).color
    let neutral = tokens.palette.surfaceMuted.color
    let gain = tokens.palette.surfaceMuted.mixed(with: tokens.palette.gain, amount: 1).color
    let scale = HistoryChartFormat.percent(model.colorScale)
    let hasHatch = model.scanCells.contains { $0.entry?.sourcesDiffer == true }
    return HistoryFlowLayout(spacing: 12, lineSpacing: 4) {
      HStack(spacing: 5) {
        Text(verbatim: "\u{2212}\(scale)")
          .font(style.smallFont)
          .foregroundStyle(style.ink3)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(LinearGradient(colors: [loss, neutral, gain], startPoint: .leading, endPoint: .trailing))
          .frame(width: isCompact ? 54 : 84, height: 9)
        Text(verbatim: "+\(scale)")
          .font(style.smallFont)
          .foregroundStyle(style.ink3)
      }
      HStack(spacing: 5) {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .stroke(style.ruleSoft, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
          .frame(width: 9, height: 9)
        Text(verbatim: "No scan")
          .font(style.smallFont)
          .foregroundStyle(style.ink3)
      }
      if hasHatch {
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(neutral)
            .overlay(
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(style.ink3, lineWidth: 1))
            .frame(width: 9, height: 9)
          Text(verbatim: "Sources changed")
            .font(style.smallFont)
            .foregroundStyle(style.ink3)
        }
      }
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func detail(model: CalendarHeatmapModel, style: HistoryChartStyle, activeID: String?)
    -> some View
  {
    if let activeID, let cell = model.cell(id: activeID) {
      let lines = CalendarHeatmapModel.lines(for: cell, timeZone: input.timeZone)
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: lines[0])
          .font(style.captionFont)
          .foregroundStyle(style.ink3)
        if let entry = cell.entry {
          Text(verbatim: HistoryChartFormat.usd(entry.point.totalValueUsd))
            .font(style.displayFont(26, relativeTo: .title2))
            .foregroundStyle(style.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(verbatim: CalendarHeatmapModel.changeLine(entry, timeZone: input.timeZone))
            .font(style.bodyFont)
            .foregroundStyle(changeColor(entry, style: style))
            .fixedSize(horizontal: false, vertical: true)
          if entry.sourcesDiffer {
            Text(verbatim: "Different wallets or exchanges were read, so this is not a market move.")
              .font(style.captionFont)
              .foregroundStyle(style.ink2)
              .fixedSize(horizontal: false, vertical: true)
          }
          if entry.point.hasUnpricedHoldings {
            Text(verbatim: "Some holdings have no price.")
              .font(style.captionFont)
              .foregroundStyle(style.ink3)
          }
        } else {
          Text(verbatim: "No scan on this day")
            .font(style.bodyFont)
            .foregroundStyle(style.ink2)
        }
        extremes(model: model, style: style)
          .padding(.top, 14)
      }
      .accessibilityHidden(true)
    }
  }

  /// The best and worst day among those that can be read as market moves.
  @ViewBuilder
  private func extremes(model: CalendarHeatmapModel, style: HistoryChartStyle) -> some View {
    if let best = model.bestDay, let worst = model.worstDay, best.id != worst.id {
      VStack(alignment: .leading, spacing: 3) {
        extremeRow("Best day", cell: best, style: style)
        extremeRow("Worst day", cell: worst, style: style)
      }
    }
  }

  private func extremeRow(_ title: String, cell: CalendarHeatmapModel.Cell, style: HistoryChartStyle)
    -> some View
  {
    let change = cell.entry?.marketChange ?? 0
    return VStack(alignment: .leading, spacing: 0) {
      Text(verbatim: title)
        .font(style.smallFont)
        .foregroundStyle(style.ink3)
      HStack(spacing: 6) {
        Text(verbatim: HistoryChartFormat.signedPercent(change))
          .font(style.numberFont(13, relativeTo: .footnote))
          .foregroundStyle(change >= 0 ? style.gain : style.loss)
        Text(verbatim: CalendarHeatmapModel.title(cell.day, timeZone: input.timeZone))
          .font(style.captionFont)
          .foregroundStyle(style.ink2)
          .lineLimit(1)
      }
    }
  }

  private func changeColor(_ entry: CalendarHeatmapModel.Entry, style: HistoryChartStyle) -> Color {
    guard let change = entry.marketChange else { return style.ink2 }
    if abs(change) < 0.0005 { return style.ink2 }
    return change > 0 ? style.gain : style.loss
  }
}
