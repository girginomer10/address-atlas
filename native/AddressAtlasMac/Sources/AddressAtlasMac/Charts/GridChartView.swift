import AddressAtlasCore
import SwiftUI

/// Waffle: 100 squares, one per percent, filled in reading order. The squares
/// are shared out by largest remainder, so they always add up to exactly 100
/// and the biggest slices lose or gain a square only when the fractions say so.
struct GridChartView: View {
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
    ChartKitFrame(data: data, density: input.density, viewName: "Grid") { size in
      content(in: size)
    }
  }

  private func slices() -> [ChartKitSlice] {
    input.density == .full
      ? data.folded(maxCount: 8, minShare: 0.01)
      : data.folded(maxCount: 6, minShare: 0.02, minimumKept: 4)
  }

  private func content(in size: CGSize) -> some View {
    let slices = slices()
    let isFull = input.density == .full
    let colors = tokens.chartKitColors(for: slices)
    return ChartKitGraphicLayout(
      size: size, density: input.density, legendWidth: isFull ? 240 : 128
    ) { side in
      waffle(slices, colors: colors, side: side)
    } legend: {
      ChartKitLegend(
        slices: slices, layout: .column, showsValue: isFull, fontSize: isFull ? 13 : 11,
        colors: colors, state: $interaction, onSelect: input.onSelect)
    }
  }

  private func waffle(_ slices: [ChartKitSlice], colors: [String: AtlasRGB], side: CGFloat)
    -> some View
  {
    let style = ChartKitBlockStyle(tokens: tokens)
    let gap: CGFloat = style.borderWidth > 0 ? max(3, style.borderWidth + 1.5) : 3
    let inset = style.borderWidth / 2
    let cell = max(0, (side - inset * 2 - gap * 9) / 10)
    let counts = ChartKitWaffle.allocate(shares: slices.map(\.valueUsd))
    let owners = ChartKitWaffle.owners(counts: counts)
    let radius = min(style.cornerRadius, cell * 0.3)
    let border = style.borderWidth > 0 ? min(style.borderWidth, max(1, cell * 0.08)) : 0
    return VStack(spacing: gap) {
      ForEach(0..<10, id: \.self) { row in
        HStack(spacing: gap) {
          ForEach(0..<10, id: \.self) { column in
            let position = row * 10 + column
            if position < owners.count {
              let slice = slices[owners[position]]
              ChartKitMark(
                shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                fill: tokens.chartKitRGB(slice, in: colors).color, style: style,
                isActive: interaction.isActive(slice.id), borderWidth: border
              )
              .frame(width: cell, height: cell)
              .chartKitDimmed(interaction.isDimmed(slice.id), reduceMotion: reduceMotion)
              .contentShape(Rectangle())
              .chartKitPointerTarget(slice, state: $interaction, onSelect: input.onSelect)
            } else {
              Color.clear.frame(width: cell, height: cell)
            }
          }
        }
      }
    }
    .padding(inset)
    .frame(width: side, height: side)
    // The cells are decoration for VoiceOver; each slice is read once, with
    // its share and value, as an element of the whole grid.
    .accessibilityElement(children: .ignore)
    .accessibilityChildren {
      VStack {
        ForEach(slices) { slice in
          Text(slice.accessibilityLabel)
            .accessibilityAddTraits(slice.selection == nil ? [] : .isButton)
            .accessibilityAction {
              if let selection = slice.selection { input.onSelect(selection) }
            }
        }
      }
    }
  }
}
