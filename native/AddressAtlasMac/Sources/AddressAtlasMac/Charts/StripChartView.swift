import AddressAtlasCore
import SwiftUI

/// One bar, 100 percent wide, split into the slices. In `.full` density each
/// segment wide enough for its label has the name and share under it, and the
/// slices that are too narrow are named in a legend below. In `.compact`
/// density it is a thin bar and nothing else.
struct StripChartView: View {
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
    ChartKitFrame(data: data, density: input.density, viewName: "Strip") { size in
      strip(in: size)
    }
  }

  private func strip(in size: CGSize) -> some View {
    let style = ChartKitBlockStyle(tokens: tokens)
    let isFull = input.density == .full
    let slices =
      isFull
      ? data.folded(maxCount: 14, minShare: 0.004, minimumKept: 6)
      : data.folded(maxCount: 12, minShare: 0.01, minimumKept: 6)
    let gap: CGFloat = isFull ? (style.borderWidth > 0 ? style.borderWidth + 2.5 : 3) : 2
    let barHeight: CGFloat = isFull ? min(72, max(44, size.height * 0.2)) : 14
    let width = max(0, size.width - style.shadowReserve.width)
    let widths = ChartKitStrip.widths(shares: slices.map(\.valueUsd), width: width, gap: gap)
    var offsets: [CGFloat] = []
    var cursor: CGFloat = 0
    for segmentWidth in widths {
      offsets.append(cursor)
      cursor += segmentWidth + (segmentWidth > 0 ? gap : 0)
    }
    // Labels that cannot fit under their segment become legend entries.
    let labelled = Set(
      slices.indices.filter { index in
        isFull && fitsLabel(slices[index], width: widths[index])
      })
    let unlabelled = slices.indices.filter { !labelled.contains($0) }.map { slices[$0] }
    let colors = tokens.chartKitColors(for: slices)

    return VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topLeading) {
        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
          segment(
            slice, width: widths[index], height: barHeight, style: style,
            fill: tokens.chartKitRGB(slice, in: colors))
            .offset(x: offsets[index])
        }
      }
      .frame(width: width, height: barHeight, alignment: .topLeading)

      if isFull {
        ZStack(alignment: .topLeading) {
          ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
            if labelled.contains(index) {
              segmentLabel(slice, width: widths[index])
                .offset(x: offsets[index])
            }
          }
        }
        .frame(width: width, height: 38, alignment: .topLeading)
        .accessibilityHidden(true)

        if !unlabelled.isEmpty {
          ChartKitLegend(
            slices: unlabelled, layout: .flow, showsValue: false, fontSize: 12,
            colors: colors, state: $interaction, onSelect: input.onSelect)
        }
      }
    }
    .frame(width: size.width, height: size.height, alignment: .center)
  }

  private func segment(
    _ slice: ChartKitSlice, width: CGFloat, height: CGFloat, style: ChartKitBlockStyle,
    fill: AtlasRGB
  ) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: min(style.cornerRadius, height / 2, max(0, width / 2)), style: .continuous)
    return ChartKitMark(
      shape: shape, fill: fill.color, style: style,
      isActive: interaction.isActive(slice.id),
      borderWidth: width < 6 ? min(style.borderWidth, 1) : nil
    )
    .frame(width: width, height: height)
    .contentShape(Rectangle())
    .chartKitDimmed(interaction.isDimmed(slice.id), reduceMotion: reduceMotion)
    .chartKitTarget(slice, state: $interaction, onSelect: input.onSelect)
  }

  /// Whether the name or the share has any chance of fitting under the segment.
  private func fitsLabel(_ slice: ChartKitSlice, width: CGFloat) -> Bool {
    let needed = max(
      ChartKitLabelBudget.width(characters: slice.label.count, fontSize: 11),
      ChartKitLabelBudget.width(
        characters: ChartKitFormat.percent(slice.share).count, fontSize: 12))
    return width >= needed + 6
  }

  private func segmentLabel(_ slice: ChartKitSlice, width: CGFloat) -> some View {
    let name = Text(slice.label)
      .font(tokens.chartKitLabelFont(11))
      .foregroundStyle(tokens.color(.ink2))
    let share = Text(ChartKitFormat.percent(slice.share))
      .font(tokens.chartKitNumberFont(13, weight: .bold))
      .foregroundStyle(tokens.color(.ink))
    return ViewThatFits(in: .horizontal) {
      VStack(alignment: .leading, spacing: 1) {
        name.lineLimit(1).fixedSize()
        share.lineLimit(1).fixedSize()
      }
      name.lineLimit(1).fixedSize()
      share.lineLimit(1).fixedSize()
      Color.clear.frame(width: 0, height: 0)
    }
    .padding(.leading, 2)
    .frame(width: width, alignment: .leading)
  }
}
