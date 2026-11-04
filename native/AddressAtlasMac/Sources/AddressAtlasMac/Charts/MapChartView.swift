import AddressAtlasCore
import SwiftUI

/// Treemap: every slice is a block whose area is its share of the portfolio.
///
/// Labels scale with the block and are dropped, whole, when they do not fit.
/// Grouped by asset in `.full` density, a block big enough to stay legible is
/// split by network (or by state when something is staked, unbonding, or
/// earning rewards); a block that is too small keeps its single label.
struct MapChartView: View {
  private let input: PortfolioChartInput
  private let data: ChartKitData

  @Environment(\.atlasTheme) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var interaction = ChartKitInteractionState()

  /// `initialInteraction` starts the chart with a slice hovered or picked, for
  /// previews and screenshots of those states; the screens never pass it.
  init(
    input: PortfolioChartInput,
    initialInteraction: ChartKitInteractionState = ChartKitInteractionState()
  ) {
    self.input = input
    _interaction = State(initialValue: initialInteraction)
    // Where a coin sits is the useful split of a block, so the second level is
    // the network (an exchange counts as one).
    self.data = ChartKitData(
      input: input,
      nesting: input.density == .full && input.grouping == .asset && input.coinKey == nil
        ? .grouping(.network) : .none)
  }

  var body: some View {
    ChartKitFrame(data: data, density: input.density, viewName: "Map") { size in
      map(in: size)
    }
  }

  // MARK: Layout

  private func map(in size: CGSize) -> some View {
    let style = ChartKitBlockStyle(tokens: tokens)
    let isFull = input.density == .full
    let slices = data.folded(maxCount: isFull ? 18 : 9, minShare: isFull ? 0.01 : 0.03)
    let reserve = style.shadowReserve
    func cells(legendHeight: CGFloat) -> [CGRect] {
      let bounds = CGRect(
        x: 0, y: 0, width: max(0, size.width - reserve.width),
        height: max(0, size.height - reserve.height - legendHeight))
      return ChartKitTreemap.layout(values: slices.map(\.valueUsd), in: bounds)
    }
    var legendHeight: CGFloat = 0
    var rects = cells(legendHeight: 0)
    var unlabelled = unlabelledSlices(slices, cells: rects, style: style)
    // Blocks too small to name themselves are named in a legend under the map.
    if isFull, !unlabelled.isEmpty {
      legendHeight = unlabelled.count > 6 ? 46 : 26
      rects = cells(legendHeight: legendHeight)
      unlabelled = unlabelledSlices(slices, cells: rects, style: style)
    }
    let legend = isFull ? unlabelled : []
    let colors = tokens.chartKitColors(for: slices)
    let mapHeight = max(0, size.height - (legend.isEmpty ? 0 : legendHeight + 6))
    return VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topLeading) {
        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
          block(slice, cell: rects[index], style: style, colors: colors)
        }
      }
      .frame(width: size.width, height: mapHeight, alignment: .topLeading)
      if !legend.isEmpty {
        ChartKitLegend(
          slices: legend, layout: .flow, showsValue: false, fontSize: 12, colors: colors,
          state: $interaction, onSelect: input.onSelect)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }

  /// The slices whose block cannot carry even its name (an estimate; the label
  /// itself is still measured when drawn).
  private func unlabelledSlices(
    _ slices: [ChartKitSlice], cells: [CGRect], style: ChartKitBlockStyle
  ) -> [ChartKitSlice] {
    zip(slices, cells).filter { slice, cell in
      let rect = blockRect(for: cell, style: style)
      let padding = labelPadding(for: rect.size, style: style)
      let fitsWidth = ChartKitLabelBudget.fits(
        characters: slice.label.count, fontSize: 10, in: rect.width - padding * 2)
      return !(fitsWidth && rect.height >= 10 * 1.4 + padding * 2)
    }.map(\.0)
  }

  /// The cell less the gap around it, but never less than a 2-point sliver, so a
  /// slice worth a percent or two is still there to see and to point at.
  private func blockRect(for cell: CGRect, style: ChartKitBlockStyle) -> CGRect {
    let inset = min(style.gap / 2, max(0, (min(cell.width, cell.height) - 2) / 2))
    return cell.insetBy(dx: inset, dy: inset)
  }

  @ViewBuilder
  private func block(
    _ slice: ChartKitSlice, cell: CGRect, style: ChartKitBlockStyle, colors: [String: AtlasRGB]
  ) -> some View {
    let rect = blockRect(for: cell, style: style)
    if rect.width >= 2, rect.height >= 2 {
      let fill = tokens.chartKitRGB(slice, in: colors)
      let ink = tokens.chartKitInk(on: fill)
      let nesting = nestedLayout(for: slice, in: rect.size)
      let padding = labelPadding(for: rect.size, style: style)
      ZStack(alignment: .topLeading) {
        ChartKitBlock(
          style: style, fill: fill.color, size: rect.size, isActive: interaction.isActive(slice.id))
        if let nesting {
          nested(slice, layout: nesting, fill: fill, ink: ink, padding: padding, style: style)
        } else {
          ChartKitBlockLabel(
            name: slice.label, share: slice.share, valueUsd: slice.valueUsd,
            ink: ink.color, size: rect.size, density: input.density,
            showsValue: input.density == .full
          )
          .padding(padding)
        }
      }
      .frame(width: rect.width, height: rect.height, alignment: .topLeading)
      .contentShape(Rectangle())
      .chartKitDimmed(interaction.isDimmed(slice.id), reduceMotion: reduceMotion)
      .chartKitTarget(
        id: slice.id, selection: slice.selection,
        label: nesting == nil ? slice.accessibilityLabel : slice.accessibilityLabelWithChildren,
        help: "\(slice.label), \(ChartKitFormat.percent(slice.share)), \(ChartKitFormat.usd(slice.valueUsd))",
        state: $interaction, onSelect: input.onSelect
      )
      .offset(x: rect.minX, y: rect.minY)
    }
  }

  private func labelPadding(for size: CGSize, style: ChartKitBlockStyle) -> CGFloat {
    let base = min(max(min(size.width, size.height) * 0.1, 5), 12)
    return base + style.borderWidth
  }

  // MARK: Nested level

  private struct Nesting {
    var headerHeight: CGFloat
    var children: [(slice: ChartKitSlice, rect: CGRect)]
  }

  /// The second level of an asset block, or nil when the block is flat: not in
  /// `.full` density, no split, or a block where every child would not stay at
  /// least `minimumChild` points on its short side.
  private func nestedLayout(for slice: ChartKitSlice, in size: CGSize) -> Nesting? {
    guard input.density == .full, !slice.isOther else { return nil }
    let minimumChild: CGFloat = 26
    guard size.width >= 170, size.height >= 110 else { return nil }
    let drawable = slice.children.filter { $0.valueUsd > 0 }
    guard drawable.count >= 2 else { return nil }
    let children = ChartKitData.fold(
      drawable, grouping: drawable[0].grouping, maxCount: 4, minShare: 0.08, minimumKept: 2,
      ofParent: slice)
    let inset: CGFloat = 6
    let header: CGFloat = 26
    let area = CGRect(
      x: inset, y: header + inset * 0.5, width: size.width - inset * 2,
      height: size.height - header - inset * 1.5)
    guard area.width > 0, area.height > 0 else { return nil }
    let cells = ChartKitTreemap.layout(values: children.map(\.valueUsd), in: area)
    let placed = zip(children, cells).map { (slice: $0, rect: $1.insetBy(dx: 1.5, dy: 1.5)) }
    // Every child must be big enough to carry its own name, or the split is
    // just unlabelled bands.
    let legible = placed.allSatisfy { child in
      min(child.rect.width, child.rect.height) >= minimumChild
        && ChartKitLabelBudget.fits(
          characters: child.slice.label.count, fontSize: 11, in: child.rect.width - 12)
    }
    guard legible else { return nil }
    return Nesting(headerHeight: header, children: placed)
  }

  private func nested(
    _ slice: ChartKitSlice, layout: Nesting, fill: AtlasRGB, ink: AtlasRGB, padding: CGFloat,
    style: ChartKitBlockStyle
  ) -> some View {
    ZStack(alignment: .topLeading) {
      header(slice, ink: ink.color)
        .padding(.horizontal, 10)
        .frame(height: layout.headerHeight, alignment: .leading)
        .padding(.top, 2)
      ForEach(Array(layout.children.enumerated()), id: \.element.slice.id) { index, child in
        let tone = fill.chartKitTone(at: index)
        let childInk = tokens.chartKitInk(on: tone)
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: style.radius(for: child.rect.size) * 0.7, style: .continuous)
            .fill(tone.color)
          ChartKitBlockLabel(
            name: child.slice.label, share: child.slice.shareOfParent,
            valueUsd: child.slice.valueUsd, ink: childInk.color, size: child.rect.size,
            density: .full, showsValue: true
          )
          .padding(6)
        }
        .frame(width: child.rect.width, height: child.rect.height, alignment: .topLeading)
        .help(
          "\(slice.label) \(child.slice.label), \(ChartKitFormat.percent(child.slice.shareOfParent)) of \(slice.label), \(ChartKitFormat.usd(child.slice.valueUsd))"
        )
        .offset(x: child.rect.minX, y: child.rect.minY)
      }
    }
  }

  /// "ETH · 27%" at the left and the value at the right, or just the name.
  private func header(_ slice: ChartKitSlice, ink: Color) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        ChartKitNameAndShare(name: slice.label, share: slice.share, size: 13)
        Spacer(minLength: 8)
        Text(ChartKitFormat.usd(slice.valueUsd))
          .font(tokens.chartKitNumberFont(13, weight: .bold))
          .lineLimit(1)
          .fixedSize()
      }
      ChartKitNameAndShare(name: slice.label, share: slice.share, size: 13)
      Text(slice.label)
        .font(tokens.chartKitLabelFont(12, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
      Color.clear.frame(width: 0, height: 0)
    }
    .foregroundStyle(ink)
  }
}
