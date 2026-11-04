import AddressAtlasCore
import SwiftUI

/// How concentrated the portfolio is: a dial from "spread out" to
/// "concentrated" with the share of the largest group in the middle, one plain
/// sentence ("57% is in one coin. Your portfolio behaves like 2.6 equal
/// holdings."), and the three largest groups with their shares.
///
/// It measures the grouping the user chose (coins by default). Clicking or
/// tapping a leader reports `.coin(key)` for coins and `.slice(grouping:key:)`
/// otherwise.
struct ConcentrationChartView: View {
  let input: PortfolioChartInput
  private let model: ConcentrationModel

  @Environment(\.atlasTheme) private var tokens
  @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

  init(input: PortfolioChartInput) {
    self.input = input
    model = ConcentrationModel(holdings: input.holdings, grouping: input.grouping)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    if !model.hasValue {
      HistoryChartMessage(
        title: "Nothing to measure yet",
        detail: "Concentration needs holdings with a price.", density: input.density)
    } else {
      HStack(alignment: .center, spacing: isCompact ? 12 : 32) {
        gauge(style: style)
          .frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: isCompact ? 8 : 16) {
          Text(verbatim: model.reading)
            .font(isCompact ? style.bodyFont : style.displayFont(19, relativeTo: .title3))
            .foregroundStyle(style.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
          leaders(style: style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      .historyAccessibility(label: model.spokenSummary)
    }
  }

  // MARK: Gauge

  private func gauge(style: HistoryChartStyle) -> some View {
    VStack(spacing: isCompact ? 2 : 6) {
      Canvas { context, size in
        drawGauge(&context, size: size, style: style)
      }
      .aspectRatio(1.7, contentMode: .fit)
      .accessibilityHidden(true)
      Text(verbatim: model.levelTitle)
        .font(style.strongFont)
        .foregroundStyle(levelColor(style: style))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }
  }

  private func levelColor(style: HistoryChartStyle) -> Color {
    switch model.concentration.level {
    case .diversified?: style.gain
    case .moderate?: style.warning
    case .concentrated?: style.loss
    case nil: style.ink2
    }
  }

  private func drawGauge(_ context: inout GraphicsContext, size: CGSize, style: HistoryChartStyle) {
    let lineWidth: CGFloat = isCompact ? 10 : 18
    let labelRoom: CGFloat = (isCompact ? 14 : 20) * textScale
    let radius = max(
      10, min(size.width / 2 - lineWidth / 2 - 2, size.height - lineWidth / 2 - labelRoom))
    let center = CGPoint(x: size.width / 2, y: size.height - labelRoom)
    // The warning ink is dark enough for text; as a fill in a light theme it
    // reads muddy, so lighten it there.
    let amber =
      tokens.variant.isDark ? tokens.palette.warning : tokens.palette.warning.mixed(with: .white, amount: 0.3)
    let colors: [Color] = [style.gain, amber.color, style.loss]
    let rounded = tokens.shape.pillControls

    func point(_ fraction: Double, radius: CGFloat) -> CGPoint {
      let angle = Double.pi + Double.pi * fraction
      return CGPoint(
        x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    // Three bands with a small gap between them.
    let gap = 0.012
    for band in 0..<3 {
      let start = Double(band) / 3 + (band == 0 ? 0 : gap)
      let end = Double(band + 1) / 3 - (band == 2 ? 0 : gap)
      var arc = Path()
      let steps = 36
      for step in 0...steps {
        let fraction = start + (end - start) * Double(step) / Double(steps)
        let p = point(fraction, radius: radius)
        if step == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
      }
      context.stroke(
        arc, with: .color(colors[band].opacity(0.9)),
        style: StrokeStyle(lineWidth: lineWidth, lineCap: rounded ? .round : .butt))
      if style.markBorderWidth > 0 {
        let outer = arc.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        context.stroke(outer, with: .color(style.ink), lineWidth: style.markBorderWidth * 0.6)
      }
    }

    // The marker: a knob on the dial.
    let knob = point(model.gaugePosition, radius: radius)
    let knobRadius = lineWidth * 0.78
    let knobShape = Path(
      ellipseIn: CGRect(
        x: knob.x - knobRadius, y: knob.y - knobRadius, width: knobRadius * 2,
        height: knobRadius * 2))
    context.fill(knobShape, with: .color(style.ink))
    context.stroke(knobShape, with: .color(style.surface), lineWidth: 2)

    // The share of the largest group, in the middle of the dial. A narrow dial
    // (a phone in portrait) has no room for the caption under it or for the
    // labels at its ends, and a smaller figure; the sentence beside the dial and
    // the level title below it say the same.
    let roomy = size.width >= 210
    let numberSize: CGFloat = min(isCompact ? 24 : 40, max(14, radius * (roomy ? 0.62 : 0.5)))
    context.historyDraw(
      model.topShareText, font: style.displayFont(numberSize, relativeTo: .largeTitle),
      color: style.ink, at: CGPoint(x: center.x, y: center.y - radius * 0.28), anchor: .center)
    if roomy {
      let caption = "in one \(model.singular)"
      context.historyDraw(
        caption, font: style.captionFont, color: style.ink3,
        at: CGPoint(x: center.x, y: center.y - radius * 0.28 + numberSize * 0.62 + 4), anchor: .top)
    }

    // Ends of the dial.
    // Each label starts at its end of the dial and runs inward, so neither is
    // cut by the edge of the card. The compact dial has no room for them; its
    // level title says the same.
    guard !isCompact, roomy else { return }
    let labelY = center.y + lineWidth / 2 + 4
    let half = size.width / 2 - 2
    if let spread = context.historyFit(
      "Spread out", font: style.smallFont, maxWidth: half, minimumCharacters: 3)
    {
      context.historyDraw(
        spread, font: style.smallFont, color: style.ink3,
        at: CGPoint(x: max(2, center.x - radius - lineWidth / 2), y: labelY), anchor: .topLeading)
    }
    if let concentrated = context.historyFit(
      "Concentrated", font: style.smallFont, maxWidth: half, minimumCharacters: 3)
    {
      context.historyDraw(
        concentrated, font: style.smallFont, color: style.ink3,
        at: CGPoint(x: min(size.width - 2, center.x + radius + lineWidth / 2), y: labelY),
        anchor: .topTrailing)
    }
  }

  // MARK: Leaders

  private func leaders(style: HistoryChartStyle) -> some View {
    VStack(alignment: .leading, spacing: isCompact ? 4 : 8) {
      ForEach(model.concentration.leaders) { entry in
        let color = style.color(grouping: model.grouping, key: entry.id, label: entry.label).color
        Button {
          input.onSelect(model.selection(for: entry))
        } label: {
          HStack(spacing: isCompact ? 6 : 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(color)
              .frame(width: isCompact ? 8 : 11, height: isCompact ? 8 : 11)
              .overlay {
                if style.markBorderWidth > 0 {
                  RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(style.ink, lineWidth: 1)
                }
              }
            Text(verbatim: entry.label)
              .font(isCompact ? style.captionFont : style.bodyFont)
              .foregroundStyle(style.ink)
              .lineLimit(1)
              .frame(minWidth: isCompact ? 34 : 56, alignment: .leading)
            GeometryReader { proxy in
              ZStack(alignment: .leading) {
                Capsule().fill(style.ruleSoft)
                Capsule().fill(color)
                  .frame(width: max(3, proxy.size.width * CGFloat(entry.share)))
              }
            }
            .frame(height: isCompact ? 5 : 7)
            Text(verbatim: HistoryChartFormat.percent(entry.share))
              .font(style.numberFont(isCompact ? 10.5 : 13, relativeTo: .caption))
              .foregroundStyle(style.ink2)
              .lineLimit(1)
              .frame(minWidth: isCompact ? 26 : 38, alignment: .trailing)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(entry.label), \(HistoryChartFormat.percent(entry.share)) of your portfolio")
        .accessibilityAddTraits(.isButton)
      }
    }
  }
}
