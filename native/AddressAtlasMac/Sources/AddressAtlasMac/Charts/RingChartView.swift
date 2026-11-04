import AddressAtlasCore
import SwiftUI

/// Donut: each slice is an arc, the total sits in the middle, and a legend lists
/// every slice with its share. Hovering or picking a slice shows it in the
/// middle. A small gap separates the arcs.
struct RingChartView: View {
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
    self.data = ChartKitData(input: input)
  }

  var body: some View {
    ChartKitFrame(data: data, density: input.density, viewName: "Ring") { size in
      content(in: size)
    }
  }

  private func slices() -> [ChartKitSlice] {
    input.density == .full
      ? data.folded(maxCount: 8, minShare: 0.02)
      : data.folded(maxCount: 6, minShare: 0.03, minimumKept: 4)
  }

  private func content(in size: CGSize) -> some View {
    let slices = slices()
    let isFull = input.density == .full
    let colors = tokens.chartKitColors(for: slices)
    return ChartKitGraphicLayout(
      size: size, density: input.density, legendWidth: isFull ? 240 : 128
    ) { side in
      ring(slices, colors: colors, side: side)
    } legend: {
      ChartKitLegend(
        slices: slices, layout: .column, showsValue: isFull, fontSize: isFull ? 13 : 11,
        colors: colors, state: $interaction, onSelect: input.onSelect)
    }
  }

  private func ring(_ slices: [ChartKitSlice], colors: [String: AtlasRGB], side: CGFloat)
    -> some View
  {
    let style = ChartKitBlockStyle(tokens: tokens)
    let pop: CGFloat = 4
    let outer = max(0, side / 2 - pop)
    let thickness = outer * (style.borderWidth >= 2 ? 0.40 : 0.38)
    let inner = outer - thickness
    let arcs = ChartKitSunburst.tile(values: slices.map(\.valueUsd))
    let gap = max(3, style.borderWidth * 2) / max(1, (outer + inner) / 2)
    let active = interaction.activeID.flatMap { id in slices.first { $0.id == id } }
    return ZStack {
      ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
        let isActive = interaction.isActive(slice.id)
        let arc = ChartKitSunburst.inset(arcs[index], gapAngle: gap)
        let segment = ChartKitDonutSegment(
          arc: arc, innerRadius: inner, outerRadius: isActive ? outer + pop : outer)
        ChartKitMark(
          shape: segment, fill: tokens.chartKitRGB(slice, in: colors).color, style: style,
          isActive: false,
          borderWidth: style.arcBorder(
            for: arc, midRadius: (inner + outer) / 2, compact: input.density == .compact)
        )
        .contentShape(segment)
        .chartKitDimmed(interaction.isDimmed(slice.id), reduceMotion: reduceMotion)
        .chartKitTarget(slice, state: $interaction, onSelect: input.onSelect)
      }
      ChartKitRingCenter(
        title: ChartKitFormat.usd(active?.valueUsd ?? data.totalValueUsd),
        caption: active.map { "\($0.label) · \(ChartKitFormat.percent($0.share))" }
          ?? ChartKitFormat.count(data.drawable.count, of: data.grouping),
        diameter: inner * 2
      )
      .allowsHitTesting(false)
    }
    .frame(width: side, height: side)
  }
}
