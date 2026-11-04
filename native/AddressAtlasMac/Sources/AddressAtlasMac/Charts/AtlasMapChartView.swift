import AddressAtlasCore
import SwiftUI

/// The portfolio as a map: every slice is a "country" whose area is its value,
/// laid out as a weighted Voronoi treemap (a power diagram solved to within
/// about 2% of each area) inside a rounded boundary.
///
/// Cells take their colour from the theme (coin, network, state or type colour;
/// wallets and exchanges get a stable pick from the categorical set). Slices
/// too small to read fold into one "Other" cell. With asset grouping and
/// holdings on a few big networks the map can nest: network regions that hold
/// coin cells (see `AtlasMapNesting`). Hover on macOS and tap on iOS show a
/// tooltip and call `input.onSelect`.
struct AtlasMapChartView: View {
  let input: PortfolioChartInput
  private let plan: AtlasMapPlan

  @Environment(\.atlasTheme) private var tokens
  @State private var active: String?
  @State private var cache = HistoryLayoutCache<AtlasMapKey, AtlasMapLayout>()

  init(input: PortfolioChartInput) {
    self.init(input: input, nesting: .automatic)
  }

  init(input: PortfolioChartInput, nesting: AtlasMapNesting) {
    self.input = input
    plan = AtlasMapModel.plan(
      holdings: input.holdings, grouping: input.grouping, compact: input.density == .compact,
      nesting: nesting)
  }

  private var isCompact: Bool { input.density == .compact }

  var body: some View {
    if plan.isEmpty {
      HistoryChartMessage(
        title: input.holdings.isEmpty ? "Nothing to show yet" : "No priced holdings",
        detail: input.holdings.isEmpty
          ? "Scan a wallet or exchange to draw your map."
          : "Holdings without a price have no area on the map.",
        density: input.density)
    } else {
      VStack(spacing: 6) {
        GeometryReader { proxy in
          map(size: proxy.size)
        }
        if let note = FlowChartModel.unpricedNote(count: plan.unpricedCount) {
          Text(verbatim: note)
            .font(HistoryChartStyle(tokens: tokens, density: input.density).captionFont)
            .foregroundStyle(tokens.color(.ink3))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  @ViewBuilder
  private func map(size: CGSize) -> some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let radius = tokens.shape.radiusLarge
    let layout = cache.value(
      for: AtlasMapModel.key(size: size, compact: isCompact, cornerRadius: radius)
    ) {
      AtlasMapModel.layout(plan: plan, size: size, cornerRadius: radius)
    }
    let current = active
    let grouping = plan.grouping
    let onSelect = input.onSelect
    Canvas { context, canvasSize in
      AtlasMapPainter(layout: layout, style: style, active: current, grouping: grouping)
        .paint(&context, size: canvasSize)
    }
    .historyPointer(
      active: $active,
      hitTest: { AtlasMapModel.hitTest($0, layout: layout) },
      onActivate: { id in
        if let cell = layout.cell(id),
          let selection = AtlasMapModel.selection(for: cell, grouping: grouping)
        {
          onSelect(selection)
        }
      }
    )
    .accessibilityChildren {
      ForEach(layout.cells) { cell in
        let selection = AtlasMapModel.selection(for: cell, grouping: grouping)
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(AtlasMapModel.accessibilityLabel(for: cell))
          .accessibilityAddTraits(selection == nil ? [] : .isButton)
          .accessibilityAction {
            if let selection { onSelect(selection) }
          }
      }
    }
    .historyAccessibility(label: AtlasMapModel.summary(plan: plan))
  }
}

// MARK: - Painting

private struct AtlasMapPainter {
  let layout: AtlasMapLayout
  let style: HistoryChartStyle
  let active: String?
  let grouping: PortfolioGrouping

  private var tokens: AtlasThemeTokens { style.tokens }
  private var compact: Bool { style.isCompact }

  func paint(_ context: inout GraphicsContext, size: CGSize) {
    paintCells(&context)
    paintGraticule(&context, size: size)
    paintRegions(&context)
    paintLabels(&context)
    if let active, let cell = layout.cell(active) {
      HistoryTooltip(lines: AtlasMapModel.tooltipLines(for: cell), anchor: cell.pole)
        .draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
    }
  }

  // MARK: Colour

  private func rgb(_ cell: AtlasMapCell) -> AtlasRGB {
    if cell.isOther { return tokens.palette.ink3.mixed(with: tokens.palette.surface, amount: 0.4) }
    return style.color(grouping: grouping, key: cell.key, label: cell.label)
  }

  // MARK: Cells

  private static func path(_ polygon: [CGPoint]) -> Path {
    var path = Path()
    guard let first = polygon.first else { return path }
    path.move(to: first)
    for point in polygon.dropFirst() { path.addLine(to: point) }
    path.closeSubpath()
    return path
  }

  /// A cell's drawn shape: the polygon pulled in by half the gap and softened
  /// with a round join. Hard-edged themes keep sharp corners.
  private func shape(for cell: AtlasMapCell) -> (fill: Path, outline: Path, radius: CGFloat)? {
    let gap: CGFloat = 1.5
    var radius = min(tokens.shape.radiusSmall, 6)
    radius = min(radius, CGFloat(cell.poleRadius) * 0.45)
    if radius < 1 { radius = 0 }
    guard let inner = ConvexPolygon.inset(cell.polygon, by: gap + radius) else {
      guard let fallback = ConvexPolygon.inset(cell.polygon, by: gap) else { return nil }
      let path = Self.path(fallback)
      return (path, path, 0)
    }
    let path = Self.path(inner)
    guard radius > 0 else { return (path, path, 0) }
    let grown = path.strokedPath(StrokeStyle(lineWidth: radius * 2, lineJoin: .round))
    return (path, path.union(grown), radius)
  }

  private func paintCells(_ context: inout GraphicsContext) {
    let border = style.markBorderWidth
    for cell in layout.cells {
      guard let shape = shape(for: cell) else { continue }
      let dim = active.map { $0 != cell.id } ?? false
      let color = rgb(cell).color.opacity(dim ? 0.5 : 1)
      if shape.radius > 0 {
        context.fill(shape.outline, with: .color(color))
      } else {
        context.fill(shape.fill, with: .color(color))
      }
      if border > 0 {
        context.stroke(
          shape.outline, with: .color(style.ink.opacity(dim ? 0.5 : 1)),
          style: StrokeStyle(lineWidth: border, lineJoin: .round))
      } else if active == cell.id {
        context.stroke(
          shape.outline, with: .color(style.ink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
      }
    }
  }

  /// Very faint meridians and parallels over the map, clipped to its outline.
  /// Hard-edged themes skip them: their borders already carry the structure.
  private func paintGraticule(_ context: inout GraphicsContext, size: CGSize) {
    guard !tokens.shape.hasBoldBorders, size.width > 120, size.height > 80 else { return }
    let outline = Self.path(layout.boundary)
    var lines = Path()
    let meridians = compact ? 3 : 5
    for index in 1...meridians {
      let x = size.width * CGFloat(index) / CGFloat(meridians + 1)
      let bow = size.width * 0.05 * (CGFloat(index) - CGFloat(meridians + 1) / 2)
      lines.move(to: CGPoint(x: x, y: 0))
      lines.addQuadCurve(
        to: CGPoint(x: x, y: size.height), control: CGPoint(x: x + bow, y: size.height / 2))
    }
    let parallels = compact ? 2 : 3
    for index in 1...parallels {
      let y = size.height * CGFloat(index) / CGFloat(parallels + 1)
      lines.move(to: CGPoint(x: 0, y: y))
      lines.addQuadCurve(
        to: CGPoint(x: size.width, y: y),
        control: CGPoint(x: size.width / 2, y: y + size.height * 0.08))
    }
    context.drawLayer { layer in
      layer.clip(to: outline)
      layer.stroke(lines, with: .color(style.ink.opacity(0.06)), lineWidth: 0.75)
    }
  }

  // MARK: Regions

  private func paintRegions(_ context: inout GraphicsContext) {
    guard !layout.regions.isEmpty else { return }
    let width = tokens.shape.hasBoldBorders ? style.markBorderWidth + 1 : 2
    for region in layout.regions {
      guard let inner = ConvexPolygon.inset(region.polygon, by: 0.5) else { continue }
      context.stroke(
        Self.path(inner), with: .color(style.ink.opacity(0.85)),
        style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }
  }

  private func regionTags(_ context: inout GraphicsContext) -> [(rect: CGRect, text: String)] {
    let font = tokens.font(.label, size: 9.5, relativeTo: .caption2, weight: .bold)
    var tags: [(CGRect, String)] = []
    for region in layout.regions {
      let text = region.label.uppercased()
      let size = context.historyMeasure(text, font: font)
      let pill = CGSize(width: size.width + 10, height: size.height + 4)
      guard
        let center = AtlasMapModel.cornerLabelCenter(
          polygon: region.polygon, size: pill, margin: 3)
      else { continue }
      tags.append((CGRect(x: center.x - pill.width / 2, y: center.y - pill.height / 2, width: pill.width, height: pill.height), text))
    }
    return tags
  }

  // MARK: Labels

  private func paintLabels(_ context: inout GraphicsContext) {
    let nameFont = tokens.font(
      .body, size: compact ? 10 : 12.5, relativeTo: .footnote, weight: .semibold)
    let valueFont = style.numberFont(compact ? 9 : 11, relativeTo: .caption)
    let tagFont = tokens.font(.label, size: 9.5, relativeTo: .caption2, weight: .bold)

    // Region tags first, so cell labels can keep clear of them.
    let tags = regionTags(&context)
    for tag in tags {
      let pill = RoundedRectangle(cornerRadius: style.blockRadius(for: tag.rect.height), style: .continuous)
        .path(in: tag.rect)
      context.fill(pill, with: .color(style.surface.opacity(0.92)))
      context.stroke(pill, with: .color(style.ink), lineWidth: max(1, style.markBorderWidth * 0.6))
      context.historyDraw(
        tag.text, font: tagFont, color: style.ink, at: CGPoint(x: tag.rect.midX, y: tag.rect.midY))
    }
    let avoid = tags.map { $0.rect.insetBy(dx: -2, dy: -2) }

    for cell in layout.cells {
      let dim = active.map { $0 != cell.id } ?? false
      guard let shape = shape(for: cell),
        let drawn = ConvexPolygon.inset(cell.polygon, by: 1.5 + shape.radius * 0.5)
      else { continue }
      var variants = AtlasMapModel.labelVariants(cell: cell, compact: compact)
      // A last resort for a long name in a small cell: cut it to the cell.
      if let cut = context.historyFit(
        cell.label, font: nameFont, maxWidth: CGFloat(cell.poleRadius) * 1.8)
      {
        variants.append([cut])
      }
      let plan = AtlasMapModel.planLabel(
        polygon: drawn, variants: variants, margin: compact ? 0.5 : 1.5, avoiding: avoid
      ) { text, index in
        context.historyMeasure(text, font: index == 0 ? nameFont : valueFont)
      }
      guard let plan else { continue }
      let ink = style.ink(on: rgb(cell)).opacity(dim ? 0.55 : 1)
      var y = plan.center.y - plan.lineSizes.map(\.height).reduce(0, +) / 2
      for (index, line) in plan.lines.enumerated() {
        context.historyDraw(
          line, font: index == 0 ? nameFont : valueFont, color: ink,
          at: CGPoint(x: plan.center.x, y: y), anchor: .top)
        y += plan.lineSizes[index].height
      }
    }
  }
}
