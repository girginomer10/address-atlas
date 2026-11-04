import AddressAtlasCore
import SwiftUI

/// Sunburst: the inner ring is the primary grouping and the outer ring splits
/// each slice by a second one, so each outer arc sits exactly outside the
/// slice it belongs to.
///
/// The second grouping is chosen to add information (see
/// `ChartKitData.secondaryGrouping`): grouped by asset it is the holding state
/// when anything is staked, unbonding, or earning rewards, otherwise the
/// network; every other grouping splits by asset. Outer arcs are lighter and
/// darker tones of their slice's colour, and the legend lists them under it.
struct RingsInRingsChartView: View {
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
    self.data = ChartKitData(input: input, nesting: .automatic)
  }

  var body: some View {
    ChartKitFrame(data: data, density: input.density, viewName: "Rings in rings") { size in
      content(in: size)
    }
  }

  /// The inner-ring slices, each with at most five outer parts.
  private func slices() -> [ChartKitSlice] {
    let isFull = input.density == .full
    let parents =
      isFull
      ? data.folded(maxCount: 7, minShare: 0.02, minimumKept: 4)
      : data.folded(maxCount: 6, minShare: 0.03, minimumKept: 4)
    let secondary = data.secondaryGrouping ?? data.grouping
    return parents.map { parent in
      guard !parent.isOther else { return parent }
      let children = ChartKitData.fold(
        parent.children.filter { $0.valueUsd > 0 }, grouping: secondary, maxCount: 5,
        minShare: 0.03, minimumKept: 3, ofParent: parent)
      return parent.replacingChildren(children)
    }
  }

  private func content(in size: CGSize) -> some View {
    let slices = slices()
    let isFull = input.density == .full
    let colors = tokens.chartKitColors(for: slices)
    return ChartKitGraphicLayout(
      size: size, density: input.density, legendWidth: isFull ? 250 : 128
    ) { side in
      sunburst(slices, colors: colors, side: side)
    } legend: {
      ChartKitLegend(
        slices: legendSlices(slices, availableHeight: size.height),
        layout: .column, showsValue: isFull, fontSize: isFull ? 12.5 : 11,
        color: { slice, parent, index in
          guard let parent else { return tokens.chartKitRGB(slice, in: colors) }
          return tokens.chartKitRGB(parent, in: colors).chartKitTone(at: index)
        },
        showsChildren: isFull,
        state: $interaction, onSelect: input.onSelect)
    }
  }

  /// Slices with their parts listed, as many as the height allows; later ones
  /// are listed without their parts.
  private func legendSlices(_ slices: [ChartKitSlice], availableHeight: CGFloat) -> [ChartKitSlice] {
    guard input.density == .full else { return slices }
    var rows = slices.count
    let budget = Int(availableHeight / 21)
    return slices.map { slice in
      let parts = slice.children.filter { $0.valueUsd > 0 }.count
      guard parts > 0, rows + parts <= budget else { return slice.replacingChildren([]) }
      rows += parts
      return slice
    }
  }

  // MARK: Drawing

  private func sunburst(_ slices: [ChartKitSlice], colors: [String: AtlasRGB], side: CGFloat)
    -> some View
  {
    let style = ChartKitBlockStyle(tokens: tokens)
    let pop: CGFloat = 4
    let radius = max(0, side / 2 - pop)
    let hole = radius * 0.34
    let innerBand = (radius * 0.37, radius * 0.66)
    let outerBand = (radius * 0.69, radius)
    let gapPoints = max(3, style.borderWidth * 2)
    let innerGap = gapPoints / max(1, (innerBand.0 + innerBand.1) / 2)
    let outerGap = gapPoints / max(1, (outerBand.0 + outerBand.1) / 2)
    let rings = ChartKitSunburst.rings(
      parents: slices.map(\.valueUsd),
      children: slices.map { $0.children.map(\.valueUsd) })
    let active = activeSlices(in: slices)
    let isCompact = input.density == .compact

    return ZStack {
      ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
        let base = tokens.chartKitRGB(slice, in: colors)
        let parentActive = interaction.isActive(slice: slice.id)
        // Inner arc.
        let innerArc = ChartKitSunburst.inset(rings.inner[index], gapAngle: innerGap)
        let inner = ChartKitDonutSegment(
          arc: innerArc,
          innerRadius: innerBand.0, outerRadius: innerBand.1 + (parentActive ? pop * 0.5 : 0))
        ChartKitMark(
          shape: inner, fill: base.color, style: style,
          borderWidth: style.arcBorder(
            for: innerArc, midRadius: (innerBand.0 + innerBand.1) / 2, compact: isCompact)
        )
        .contentShape(inner)
          .chartKitDimmed(isDimmed(slice.id, parent: nil), reduceMotion: reduceMotion)
          .chartKitTarget(slice, state: $interaction, onSelect: input.onSelect)
        // Outer arcs.
        if slice.children.isEmpty {
          let outerArc = ChartKitSunburst.inset(rings.inner[index], gapAngle: outerGap)
          let outer = ChartKitDonutSegment(
            arc: outerArc, innerRadius: outerBand.0, outerRadius: outerBand.1)
          ChartKitMark(
            shape: outer, fill: base.chartKitTone(at: 0).color, style: style,
            borderWidth: style.arcBorder(
              for: outerArc, midRadius: (outerBand.0 + outerBand.1) / 2, compact: isCompact)
          )
          .contentShape(outer)
            .chartKitDimmed(isDimmed(slice.id, parent: nil), reduceMotion: reduceMotion)
            .chartKitPointerTarget(slice, state: $interaction, onSelect: input.onSelect)
        } else {
          ForEach(Array(slice.children.enumerated()), id: \.element.id) { childIndex, child in
            let isActive = interaction.isActive(child.id)
            let outerArc = ChartKitSunburst.inset(rings.outer[index][childIndex], gapAngle: outerGap)
            let outer = ChartKitDonutSegment(
              arc: outerArc,
              innerRadius: outerBand.0, outerRadius: outerBand.1 + (isActive ? pop : 0))
            ChartKitMark(
              shape: outer, fill: base.chartKitTone(at: childIndex).color, style: style,
              borderWidth: style.arcBorder(
                for: outerArc, midRadius: (outerBand.0 + outerBand.1) / 2, compact: isCompact)
            )
            .contentShape(outer)
            .chartKitDimmed(isDimmed(child.id, parent: slice.id), reduceMotion: reduceMotion)
            .chartKitTarget(
              id: child.id, selection: child.selection,
              label: child.accessibilityLabel(inside: slice),
              help:
                "\(slice.label), \(child.label), \(ChartKitFormat.percent(child.share)), \(ChartKitFormat.usd(child.valueUsd))",
              state: $interaction, onSelect: input.onSelect)
          }
        }
      }
      ChartKitRingCenter(
        title: ChartKitFormat.usd(active?.slice.valueUsd ?? data.totalValueUsd),
        caption: caption(for: active),
        diameter: hole * 2
      )
      .allowsHitTesting(false)
    }
    .frame(width: side, height: side)
  }

  /// A slice is dimmed when something else is emphasised: not itself, not its
  /// parent, and not one of its parts.
  private func isDimmed(_ id: String, parent: String?) -> Bool {
    guard let activeID = interaction.activeID else { return false }
    if activeID == id { return false }
    if let parent, activeID == parent { return false }
    if activeID.hasPrefix(id + ">") { return false }
    return true
  }

  private func activeSlices(in slices: [ChartKitSlice]) -> (slice: ChartKitSlice, parent: ChartKitSlice?)? {
    guard let id = interaction.activeID else { return nil }
    for slice in slices {
      if slice.id == id { return (slice, nil) }
      if let child = slice.children.first(where: { $0.id == id }) { return (child, slice) }
    }
    return nil
  }

  private func caption(for active: (slice: ChartKitSlice, parent: ChartKitSlice?)?) -> String {
    guard let active else { return ChartKitFormat.count(data.drawable.count, of: data.grouping) }
    if let parent = active.parent {
      return "\(parent.label) · \(active.slice.label)"
    }
    return "\(active.slice.label) · \(ChartKitFormat.percent(active.slice.share))"
  }
}
