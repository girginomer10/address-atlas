import AddressAtlasCore
import SwiftUI

/// Where the value sits, what it is, and what state it is in: a Sankey from
/// wallets, exchanges and manual holdings (left) through coins (middle) to
/// states (right).
///
/// Colours, fonts and shapes come from the theme in the environment. Labels are
/// measured while drawing, so they never overlap: a value line is dropped when
/// it does not fit, a name is cut with an ellipsis, and a label that cannot fit
/// at all is left out (it is still read by VoiceOver and shown on hover).
/// Hover on macOS and tap on iOS show a tooltip and call `input.onSelect`.
struct FlowChartView: View {
  let input: PortfolioChartInput
  private let flow: FlowGraph

  @Environment(\.atlasTheme) private var tokens
  @State private var active: FlowChartTarget?
  @State private var cache = HistoryLayoutCache<FlowChartKey, FlowChartLayout>()

  init(input: PortfolioChartInput) {
    self.input = input
    flow = PortfolioAnalytics.flowGraph(input.holdings)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    if flow.nodes.isEmpty || flow.totalValueUsd <= 0 {
      HistoryChartMessage(
        title: input.holdings.isEmpty ? "Nothing to show yet" : "No priced holdings",
        detail: input.holdings.isEmpty
          ? "Scan a wallet or exchange to see where your value sits."
          : "Holdings without a price are not part of the flow.",
        density: input.density)
    } else {
      VStack(spacing: 6) {
        GeometryReader { proxy in
          chart(size: proxy.size)
        }
        if let note = FlowChartModel.unpricedNote(count: flow.unpriced.count) {
          Text(verbatim: note)
            .font(HistoryChartStyle(tokens: tokens, density: input.density).captionFont)
            .foregroundStyle(tokens.color(.ink3))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  @ViewBuilder
  private func chart(size: CGSize) -> some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let layout = cache.value(for: FlowChartModel.key(size: size, compact: isCompact)) {
      FlowChartModel.layout(flow: flow, size: size, compact: isCompact)
    }
    let target = active
    let onSelect = input.onSelect
    Canvas { context, canvasSize in
      FlowPainter(layout: layout, style: style, active: target).paint(&context, size: canvasSize)
    }
    .historyPointer(
      active: $active,
      hitTest: { FlowChartModel.hitTest($0, layout: layout) },
      onActivate: { target in
        if let selection = FlowChartModel.selection(for: target, in: layout) {
          onSelect(selection)
        }
      }
    )
    .accessibilityChildren {
      ForEach(layout.graph.nodes) { node in
        let selection = FlowChartModel.selection(for: node)
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(FlowChartModel.accessibilityLabel(for: node, in: layout))
          .accessibilityAddTraits(selection == nil ? [] : .isButton)
          .accessibilityAction {
            if let selection { onSelect(selection) }
          }
      }
    }
    .historyAccessibility(label: FlowChartModel.summary(flow: flow))
  }
}

// MARK: - Painting

private enum FlowChartPalette {
  /// The combined "Other" nodes: a neutral between the ink and the surface, so
  /// folded flows never shout louder than named ones.
  static func other(_ tokens: AtlasThemeTokens) -> AtlasRGB {
    tokens.palette.ink3.mixed(with: tokens.palette.surface, amount: 0.4)
  }
}

private struct FlowPainter {
  let layout: FlowChartLayout
  let style: HistoryChartStyle
  let active: FlowChartTarget?

  private var tokens: AtlasThemeTokens { style.tokens }
  private var compact: Bool { style.isCompact }

  func paint(_ context: inout GraphicsContext, size: CGSize) {
    let litLinks = active.map { FlowChartModel.highlightedLinks(for: $0, in: layout) }
    let litNodes = active.map { FlowChartModel.highlightedNodes(for: $0, in: layout) }
    paintLinks(&context, lit: litLinks)
    paintNodes(&context, lit: litNodes)
    paintLabels(&context, lit: litNodes)
    if let active, let anchor = FlowChartModel.anchor(for: active, in: layout) {
      HistoryTooltip(lines: FlowChartModel.tooltipLines(for: active, in: layout), anchor: anchor)
        .draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
    }
  }

  // MARK: Colours

  private func rgb(_ node: SankeyGraph.Node) -> AtlasRGB {
    if node.isOther { return FlowChartPalette.other(tokens) }
    switch node.column {
    case 0: return style.color(grouping: .source, key: node.key, label: node.label)
    case 1: return style.color(grouping: .asset, key: node.key, label: node.label)
    default: return style.color(grouping: .state, key: node.key, label: node.label)
    }
  }

  private func linkColor(_ link: SankeyLinkBox) -> AtlasRGB {
    if let target = layout.node(link.to), target.column == 1 { return rgb(target) }
    if let origin = layout.node(link.from) { return rgb(origin) }
    return FlowChartPalette.other(tokens)
  }

  // MARK: Links and nodes

  private func ribbon(_ link: SankeyLinkBox) -> Path {
    let thickness = max(link.thickness, 1)
    let mid = (link.x0 + link.x1) / 2
    var path = Path()
    path.move(to: CGPoint(x: link.x0, y: link.y0))
    path.addCurve(
      to: CGPoint(x: link.x1, y: link.y1),
      control1: CGPoint(x: mid, y: link.y0), control2: CGPoint(x: mid, y: link.y1))
    path.addLine(to: CGPoint(x: link.x1, y: link.y1 + thickness))
    path.addCurve(
      to: CGPoint(x: link.x0, y: link.y0 + thickness),
      control1: CGPoint(x: mid, y: link.y1 + thickness),
      control2: CGPoint(x: mid, y: link.y0 + thickness))
    path.closeSubpath()
    return path
  }

  private func paintLinks(_ context: inout GraphicsContext, lit: Set<String>?) {
    if tokens.chart.blendsWithMultiply { context.blendMode = .multiply }
    for link in layout.result.links {
      let base: Double = compact ? 0.55 : 0.5
      let opacity: Double
      if let lit { opacity = lit.contains(link.id) ? 0.85 : 0.12 } else { opacity = base }
      context.fill(ribbon(link), with: .color(linkColor(link).color.opacity(opacity)))
    }
    context.blendMode = .normal
  }

  private func paintNodes(_ context: inout GraphicsContext, lit: Set<String>?) {
    let border = style.markBorderWidth
    for box in layout.result.nodes {
      guard let node = layout.node(box.id) else { continue }
      let dim = lit.map { !$0.contains(box.id) } ?? false
      let radius = box.column == 1 ? style.blockRadius(for: min(box.rect.width, box.rect.height)) : 2
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: box.rect)
      context.fill(shape, with: .color(rgb(node).color.opacity(dim ? 0.4 : 1)))
      if border > 0 {
        context.stroke(
          shape, with: .color(style.ink.opacity(dim ? 0.4 : 1)), lineWidth: min(border, 2))
      }
    }
  }

  // MARK: Labels

  private func paintLabels(_ context: inout GraphicsContext, lit: Set<String>?) {
    let nameFont = tokens.font(
      .body, size: compact ? 9.5 : 11.5, relativeTo: .footnote, weight: .semibold)
    let valueFont = style.numberFont(compact ? 9 : 10, relativeTo: .caption2)
    let lineHeight = context.historyMeasure("Ag", font: nameFont).height
    let valueHeight = context.historyMeasure("Ag", font: valueFont).height
    var bottoms: [Int: CGFloat] = [:]

    for box in layout.result.nodes.sorted(by: { ($0.column, $0.rect.minY) < ($1.column, $1.rect.minY) }) {
      guard let node = layout.node(box.id) else { continue }
      let dim = lit.map { !$0.contains(box.id) } ?? false
      let share = HistoryChartFormat.percent(layout.share(node.value))
      let valueText =
        compact
        ? nil
        : FlowChartModel.valueLine(value: node.value, share: layout.share(node.value))

      if box.column == 1 {
        paintCoinLabel(
          &context, box: box, node: node, share: share, nameFont: nameFont, valueFont: valueFont,
          lineHeight: lineHeight, valueHeight: valueHeight, dim: dim)
        continue
      }

      // Outer columns: the label sits beside the bar, away from the links.
      let isLeft = box.column == 0
      let maxWidth =
        isLeft
        ? box.rect.minX - 8
        : layout.config.width - box.rect.maxX - 8
      guard maxWidth > 12 else { continue }
      let name = context.historyFit(node.label, font: nameFont, maxWidth: maxWidth)
      guard let name else { continue }

      // One line when the bar is short, two when there is room for the value.
      var showsValue = valueText != nil && box.rect.height >= lineHeight + valueHeight + 2
      var blockHeight = showsValue ? lineHeight + valueHeight : lineHeight
      var top = box.rect.midY - blockHeight / 2
      if let previous = bottoms[box.column], top < previous + 1 {
        showsValue = false
        blockHeight = lineHeight
        top = max(box.rect.midY - blockHeight / 2, previous + 1)
      }
      // A label taller than the room between neighbours is left out.
      let room = box.rect.height + layout.config.nodePadding
      guard lineHeight <= room + 1, top >= -1, top + blockHeight <= layout.config.height + 1 else {
        continue
      }
      let x = isLeft ? box.rect.minX - 6 : box.rect.maxX + 6
      let anchor: UnitPoint = isLeft ? .topTrailing : .topLeading
      context.historyDraw(
        name, font: nameFont, color: style.ink.opacity(dim ? 0.45 : 1),
        at: CGPoint(x: x, y: top), anchor: anchor)
      if showsValue, let valueText {
        let value =
          context.historyFit(valueText, font: valueFont, maxWidth: maxWidth)
          ?? context.historyFit(
            "\(HistoryChartFormat.usdCompact(node.value)) \u{00B7} \(share)", font: valueFont,
            maxWidth: maxWidth)
        if let value {
          context.historyDraw(
            value, font: valueFont, color: style.ink2.opacity(dim ? 0.45 : 1),
            at: CGPoint(x: x, y: top + lineHeight), anchor: anchor)
        }
      }
      bottoms[box.column] = top + blockHeight
    }
  }

  private func paintCoinLabel(
    _ context: inout GraphicsContext, box: SankeyNodeBox, node: SankeyGraph.Node, share: String,
    nameFont: Font, valueFont: Font, lineHeight: CGFloat, valueHeight: CGFloat, dim: Bool
  ) {
    let width = box.rect.width - 6
    // "Other coins" does not fit a block; "Other" does.
    let text = node.isOther ? "Other" : node.label
    guard let name = context.historyFit(text, font: nameFont, maxWidth: width) else {
      return
    }
    let ink = style.ink(on: rgb(node)).opacity(dim ? 0.5 : 1)
    let showsShare = !compact && box.rect.height >= lineHeight + valueHeight + 4
    let blockHeight = showsShare ? lineHeight + valueHeight : lineHeight
    guard lineHeight <= box.rect.height + 1 else { return }
    let top = box.rect.midY - blockHeight / 2
    context.historyDraw(
      name, font: nameFont, color: ink, at: CGPoint(x: box.rect.midX, y: top), anchor: .top)
    if showsShare {
      context.historyDraw(
        share, font: valueFont, color: ink,
        at: CGPoint(x: box.rect.midX, y: top + lineHeight), anchor: .top)
    }
  }
}
