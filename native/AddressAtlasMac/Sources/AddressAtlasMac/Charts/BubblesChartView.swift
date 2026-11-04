import AddressAtlasCore
import SwiftUI

/// Circles whose area is the slice's value, packed together with no overlaps.
///
/// The packing is deterministic (see `ChartKitBubblePacking`): the same
/// holdings give the same picture. A name and share go inside a circle that is
/// big enough to hold them; smaller ones are named in a legend under the
/// cluster in `.full` density.
struct BubblesChartView: View {
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
    ChartKitFrame(data: data, density: input.density, viewName: "Bubbles") { size in
      bubbles(in: size)
    }
  }

  private struct Placement {
    var circles: [ChartKitCircle]
    var unlabelled: [ChartKitSlice]
  }

  private func place(_ slices: [ChartKitSlice], in bounds: CGRect, style: ChartKitBlockStyle)
    -> Placement
  {
    let circles = ChartKitBubblePacking.pack(
      values: slices.map(\.valueUsd), in: bounds, gap: style.gap)
    let unlabelled = zip(slices, circles).filter { slice, circle in
      !ChartKitLabelBudget.fits(characters: slice.label.count, fontSize: 10.5, in: circle.radius * 1.6)
    }.map(\.0)
    return Placement(circles: circles, unlabelled: unlabelled)
  }

  private func bubbles(in size: CGSize) -> some View {
    let style = ChartKitBlockStyle(tokens: tokens)
    let isFull = input.density == .full
    let slices =
      isFull
      ? data.folded(maxCount: 14, minShare: 0.01)
      : data.folded(maxCount: 9, minShare: 0.02, minimumKept: 5)
    let reserve = style.shadowReserve
    let edge = style.borderWidth / 2 + 1
    func bounds(legendHeight: CGFloat) -> CGRect {
      CGRect(
        x: edge, y: edge,
        width: max(0, size.width - reserve.width - edge * 2),
        height: max(0, size.height - reserve.height - edge * 2 - legendHeight))
    }
    var placement = place(slices, in: bounds(legendHeight: 0), style: style)
    var legendHeight: CGFloat = 0
    if isFull, !placement.unlabelled.isEmpty {
      legendHeight = placement.unlabelled.count > 6 ? 46 : 26
      placement = place(slices, in: bounds(legendHeight: legendHeight), style: style)
    }
    let legend = isFull ? placement.unlabelled : []
    let colors = tokens.chartKitColors(for: slices)
    return VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topLeading) {
        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
          bubble(
            slice, circle: placement.circles[index], style: style,
            fill: tokens.chartKitRGB(slice, in: colors))
        }
      }
      .frame(
        width: size.width, height: max(0, size.height - legendHeight - 6), alignment: .topLeading)
      if !legend.isEmpty {
        ChartKitLegend(
          slices: legend, layout: .flow, showsValue: false, fontSize: 12, colors: colors,
          state: $interaction, onSelect: input.onSelect)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }

  @ViewBuilder
  private func bubble(
    _ slice: ChartKitSlice, circle: ChartKitCircle, style: ChartKitBlockStyle, fill: AtlasRGB
  ) -> some View {
    let diameter = circle.radius * 2
    if diameter >= 2 {
      let ink = tokens.chartKitInk(on: fill)
      let box = CGSize(width: diameter, height: diameter)
      ZStack {
        if let offset = style.shadow(for: box) {
          Circle().fill(style.shadowColor).offset(x: offset.width, y: offset.height)
            .accessibilityHidden(true)
        }
        ChartKitMark(
          shape: Circle(), fill: fill.color, style: style,
          isActive: interaction.isActive(slice.id),
          borderWidth: diameter < 12 ? min(style.borderWidth, 1) : nil)
        label(slice, radius: circle.radius, ink: ink.color)
      }
      .frame(width: diameter, height: diameter)
      .contentShape(Circle())
      .chartKitDimmed(interaction.isDimmed(slice.id), reduceMotion: reduceMotion)
      .chartKitTarget(slice, state: $interaction, onSelect: input.onSelect)
      .offset(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius)
    }
  }

  /// Name over share, or the name alone, or nothing: whichever fits whole in the
  /// square that sits comfortably inside the circle.
  private func label(_ slice: ChartKitSlice, radius: CGFloat, ink: Color) -> some View {
    let nameSize = min(16, max(10, radius * 0.3))
    let shareSize = min(14, max(10, radius * 0.24))
    let name = Text(slice.label)
      .font(tokens.chartKitLabelFont(nameSize, weight: .bold))
    let share = Text(ChartKitFormat.percent(slice.share))
      .font(tokens.chartKitNumberFont(shareSize, weight: .semibold))
    return ViewThatFits {
      VStack(spacing: 1) {
        name.lineLimit(1).fixedSize()
        share.lineLimit(1).fixedSize()
      }
      name.lineLimit(1).fixedSize()
      Color.clear.frame(width: 0, height: 0)
    }
    .foregroundStyle(ink)
    .frame(width: radius * 1.5, height: radius * 1.15)
    .allowsHitTesting(false)
  }
}
