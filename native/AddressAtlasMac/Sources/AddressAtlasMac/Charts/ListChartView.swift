import AddressAtlasCore
import SwiftUI

/// The table: one row per slice, largest first, each with its mark, name, a
/// share bar, the share, and the value. Coins without a price come last,
/// marked "No price", and are not part of any figure above them.
///
/// Rows give up columns before they give up legibility: below a width the share
/// bar goes, then the share. Compact density lists as many rows as fit and
/// sums up the rest.
struct ListChartView: View {
  private let input: PortfolioChartInput
  private let data: ChartKitData

  @Environment(\.atlasTheme) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
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
    ChartKitFrame(data: data, density: input.density, viewName: "List") { size in
      list(in: size)
    }
  }

  private enum Columns {
    /// Mark, name, share bar, share, value.
    case wide
    /// Mark, name, share, value.
    case medium
    /// Mark, name, value.
    case narrow
  }

  // MARK: List

  private func list(in size: CGSize) -> some View {
    let isFull = input.density == .full
    let columns: Columns =
      size.width >= 470 * textScale ? (isFull ? .wide : .medium)
      : size.width >= 290 * textScale ? .medium : .narrow
    let maxValue = data.slices.map(\.valueUsd).max() ?? 0
    let colors = tokens.chartKitColors(for: data.slices)
    let rowHeight: CGFloat = (isFull ? 44 : 32) * min(textScale, 1.6)
    // Compact: as many rows as fit, the rest summed up in one line.
    let capacity = isFull ? Int.max : max(1, Int(size.height / rowHeight))
    let total = data.slices.count + data.unpricedRows.count
    let overflow = total > capacity
    let shown = overflow ? max(1, capacity - 1) : total
    let pricedShown = Array(data.slices.prefix(shown))
    let unpricedShown = Array(data.unpricedRows.prefix(max(0, shown - pricedShown.count)))
    let hidden = Array(data.slices.dropFirst(pricedShown.count))
    let hiddenValue = hidden.map(\.valueUsd).reduce(0, +)
    let hiddenCount = total - pricedShown.count - unpricedShown.count

    let rows = VStack(spacing: 0) {
      ForEach(Array(pricedShown.enumerated()), id: \.element.id) { index, slice in
        row(slice, colors: colors, maxValue: maxValue, columns: columns, height: rowHeight)
        if index < pricedShown.count - 1 || !unpricedShown.isEmpty || overflow { rule }
      }
      ForEach(Array(unpricedShown.enumerated()), id: \.element.id) { index, unpriced in
        unpricedRow(unpriced, height: rowHeight)
        if index < unpricedShown.count - 1 || overflow { rule }
      }
      if overflow {
        moreRow(count: hiddenCount, value: hiddenValue, height: rowHeight)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)

    return Group {
      if isFull {
        // Plain rows when they fit; a scroll view only when they do not.
        ViewThatFits(in: .vertical) {
          rows
          ScrollView(.vertical, showsIndicators: false) { rows }
        }
      } else {
        rows
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }

  private var rule: some View {
    Rectangle().fill(tokens.color(.ruleSoft)).frame(height: 1).accessibilityHidden(true)
  }

  // MARK: Rows

  private func row(
    _ slice: ChartKitSlice, colors: [String: AtlasRGB], maxValue: Double, columns: Columns,
    height: CGFloat
  ) -> some View {
    let style = ChartKitBlockStyle(tokens: tokens)
    let isFull = input.density == .full
    let isActive = interaction.isActive(slice.id)
    let color = tokens.chartKitRGB(slice, in: colors)
    let subtitle = slice.subtitle ?? ChartKitFormat.holdings(slice.holdingCount)
    return HStack(spacing: isFull ? 14 : 10) {
      mark(slice, color: color, size: isFull ? 30 : 22, style: style)
      VStack(alignment: .leading, spacing: 1) {
        Text(slice.label)
          .font(tokens.chartKitBodyFont(isFull ? 14 : 13).weight(.semibold))
          .foregroundStyle(tokens.color(.ink))
          .lineLimit(1)
          .truncationMode(.tail)
        if isFull {
          Text(subtitle)
            .font(tokens.chartKitLabelFont(11))
            .foregroundStyle(tokens.color(.ink2))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
      .layoutPriority(0)

      if columns == .wide {
        shareBar(slice, color: color, maxValue: maxValue, style: style)
          .frame(minWidth: 60, idealWidth: 120, maxWidth: 200)
          .layoutPriority(-1)
      }
      if columns != .narrow {
        Text(ChartKitFormat.percent(slice.share))
          .font(tokens.chartKitNumberFont(isFull ? 13 : 12))
          .foregroundStyle(tokens.color(.ink2))
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: isFull ? 40 : 32, alignment: .trailing)
      }
      Text(ChartKitFormat.usd(slice.valueUsd, isFull ? .cents : .whole))
        .font(tokens.chartKitNumberFont(isFull ? 14 : 12, weight: .bold))
        .foregroundStyle(tokens.color(.ink))
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: isFull ? 88 : 60, alignment: .trailing)
        .layoutPriority(2)
    }
    .padding(.horizontal, 8)
    .frame(minHeight: height)
    .background {
      if isActive {
        RoundedRectangle(cornerRadius: min(style.cornerRadius, 10), style: .continuous)
          .fill(tokens.color(.surfaceMuted))
      }
    }
    .contentShape(Rectangle())
    .chartKitDimmed(interaction.isDimmed(slice.id), reduceMotion: reduceMotion)
    .chartKitTarget(slice, state: $interaction, onSelect: input.onSelect)
  }

  /// The slice's colour as a mark: a monogram disc for a coin (a square on the
  /// themes with square corners), a plain swatch for every other grouping.
  private func mark(_ slice: ChartKitSlice, color: AtlasRGB, size: CGFloat, style: ChartKitBlockStyle)
    -> some View
  {
    let isCoin = slice.grouping == .asset && !slice.isOther
    let round = tokens.shape.radiusSmall >= 8
    let shape = RoundedRectangle(
      cornerRadius: round ? size / 2 : min(style.cornerRadius, size * 0.2), style: .continuous)
    return ZStack {
      ChartKitMark(
        shape: shape, fill: color.color, style: style,
        borderWidth: style.borderWidth > 0 ? min(style.borderWidth, 2) : nil)
      if isCoin {
        // The symbol itself when it is short; its first three letters otherwise.
        Text(String(slice.label.prefix(slice.label.count > 4 ? 3 : 4)).uppercased())
          .font(tokens.chartKitLabelFont(size * 0.3, weight: .bold))
          .foregroundStyle(tokens.chartKitInk(on: color).color)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .padding(.horizontal, 2)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  /// The slice's value against the largest row, so the biggest row fills the track.
  private func shareBar(
    _ slice: ChartKitSlice, color: AtlasRGB, maxValue: Double, style: ChartKitBlockStyle
  ) -> some View {
    let fraction = maxValue > 0 ? min(1, max(0, slice.valueUsd / maxValue)) : 0
    let radius = min(style.cornerRadius, 4)
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(tokens.color(.surfaceMuted))
        if fraction > 0 {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.color)
            .blendMode(style.multiplies ? .multiply : .normal)
            .frame(width: max(3, proxy.size.width * fraction))
        }
      }
      .overlay {
        if style.borderWidth > 0 {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(style.borderColor, lineWidth: min(style.borderWidth, 1.5))
        }
      }
    }
    .frame(height: 8)
    .accessibilityHidden(true)
  }

  private func unpricedRow(_ unpriced: ChartKitUnpricedRow, height: CGFloat) -> some View {
    let isFull = input.density == .full
    let style = ChartKitBlockStyle(tokens: tokens)
    let id = "unpriced>\(unpriced.id)"
    let size: CGFloat = isFull ? 30 : 22
    let shape = RoundedRectangle(
      cornerRadius: tokens.shape.radiusSmall >= 8 ? size / 2 : min(style.cornerRadius, size * 0.2),
      style: .continuous)
    return HStack(spacing: isFull ? 14 : 10) {
      shape
        .strokeBorder(tokens.color(.ink3), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(unpriced.symbol)
          .font(tokens.chartKitBodyFont(isFull ? 14 : 13).weight(.semibold))
          .foregroundStyle(tokens.color(.ink))
          .lineLimit(1)
          .truncationMode(.tail)
        if isFull {
          Text(unpriced.name ?? ChartKitFormat.holdings(unpriced.holdingCount))
            .font(tokens.chartKitLabelFont(11))
            .foregroundStyle(tokens.color(.ink2))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
      Text("No price")
        .font(tokens.chartKitLabelFont(isFull ? 12 : 11, weight: .semibold))
        .foregroundStyle(tokens.color(.ink2))
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, 8)
    .frame(minHeight: height)
    .background {
      if interaction.isActive(id) {
        RoundedRectangle(cornerRadius: min(style.cornerRadius, 10), style: .continuous)
          .fill(tokens.color(.surfaceMuted))
      }
    }
    .contentShape(Rectangle())
    .chartKitDimmed(interaction.isDimmed(id), reduceMotion: reduceMotion)
    .chartKitTarget(
      id: id, selection: .coin(unpriced.id), label: "\(unpriced.name ?? unpriced.symbol), no price",
      help: "\(unpriced.symbol), no price", state: $interaction, onSelect: input.onSelect)
  }

  private func moreRow(count: Int, value: Double, height: CGFloat) -> some View {
    HStack {
      Text("+\(count) more")
        .font(tokens.chartKitLabelFont(12))
        .foregroundStyle(tokens.color(.ink2))
        .lineLimit(1)
      Spacer(minLength: 8)
      if value > 0 {
        Text(ChartKitFormat.usd(value))
          .font(tokens.chartKitNumberFont(12))
          .foregroundStyle(tokens.color(.ink2))
          .lineLimit(1)
          .fixedSize()
      }
    }
    .padding(.horizontal, 8)
    .frame(minHeight: height * 0.8)
    .accessibilityElement(children: .combine)
  }
}
