import AddressAtlasCore
import SwiftUI

// MARK: - Shared chart pieces
//
// Interaction, the frame every part-C1 view sits in (empty state, unpriced
// note, VoiceOver summary), the legend, and the label tiers. Everything works
// on macOS and iOS: hover uses `onContinuousHover` (pointer on Mac and iPad,
// ignored by touch), tap is `onTapGesture`, and no animation runs when Reduce
// Motion is on.

// MARK: Interaction

/// Which slice the pointer is over and which one was last picked.
struct ChartKitInteractionState: Equatable {
  var hoveredID: String?
  var selectedID: String?

  /// The slice to emphasise: the hovered one, else the picked one.
  var activeID: String? { hoveredID ?? selectedID }

  /// True when another slice is emphasised, so this one should recede.
  func isDimmed(_ id: String) -> Bool {
    guard let activeID else { return false }
    return activeID != id
  }

  func isActive(_ id: String) -> Bool { activeID == id }

  /// Whether the slice (or a child of it, by `parent>child` id) is emphasised.
  func isActive(slice id: String) -> Bool {
    guard let activeID else { return false }
    return activeID == id || activeID.hasPrefix(id + ">")
  }
}

/// Hover emphasis and tap or click selection, without any accessibility, for
/// marks that VoiceOver reads through a parent (the cells of a waffle).
private struct ChartKitPointerTarget: ViewModifier {
  var id: String
  var selection: PortfolioChartSelection?
  @Binding var state: ChartKitInteractionState
  var onSelect: (PortfolioChartSelection) -> Void

  func body(content: Content) -> some View {
    content
      .onContinuousHover { phase in
        switch phase {
        case .active:
          if state.hoveredID != id { state.hoveredID = id }
        case .ended:
          if state.hoveredID == id { state.hoveredID = nil }
        }
      }
      .onTapGesture { activate() }
  }

  private func activate() {
    guard let selection else { return }
    state.selectedID = state.selectedID == id ? nil : id
    onSelect(selection)
  }
}

private struct ChartKitTarget: ViewModifier {
  var id: String
  var selection: PortfolioChartSelection?
  var label: String
  var help: String?
  @Binding var state: ChartKitInteractionState
  var onSelect: (PortfolioChartSelection) -> Void

  func body(content: Content) -> some View {
    content
      .modifier(
        ChartKitPointerTarget(id: id, selection: selection, state: $state, onSelect: onSelect)
      )
      .help(help ?? label)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityAddTraits(traits)
      .accessibilityAction { activate() }
  }

  private var traits: AccessibilityTraits {
    guard selection != nil else { return [] }
    return state.selectedID == id ? [.isButton, .isSelected] : .isButton
  }

  private func activate() {
    guard let selection else { return }
    state.selectedID = state.selectedID == id ? nil : id
    onSelect(selection)
  }
}

extension View {
  /// Hover and tap for a mark that has no accessibility element of its own.
  func chartKitPointerTarget(
    _ slice: ChartKitSlice,
    state: Binding<ChartKitInteractionState>,
    onSelect: @escaping (PortfolioChartSelection) -> Void
  ) -> some View {
    modifier(
      ChartKitPointerTarget(
        id: slice.id, selection: slice.selection, state: state, onSelect: onSelect))
  }

  /// Makes a mark one interactive chart element: hover emphasis on Mac and
  /// iPad, tap or click to select, and a single VoiceOver element reading
  /// `label` ("Bitcoin, 57 percent, $27,980"). A slice without a selection
  /// (the folded "Other") hovers and reads but does nothing on tap.
  func chartKitTarget(
    id: String,
    selection: PortfolioChartSelection?,
    label: String,
    help: String? = nil,
    state: Binding<ChartKitInteractionState>,
    onSelect: @escaping (PortfolioChartSelection) -> Void
  ) -> some View {
    modifier(
      ChartKitTarget(
        id: id, selection: selection, label: label, help: help, state: state, onSelect: onSelect)
    )
  }

  /// The slice as a target, using its own selection and spoken label.
  func chartKitTarget(
    _ slice: ChartKitSlice,
    state: Binding<ChartKitInteractionState>,
    onSelect: @escaping (PortfolioChartSelection) -> Void
  ) -> some View {
    chartKitTarget(
      id: slice.id, selection: slice.selection, label: slice.accessibilityLabel,
      help: "\(slice.label), \(ChartKitFormat.percent(slice.share)), \(ChartKitFormat.usd(slice.valueUsd))",
      state: state, onSelect: onSelect)
  }

  /// Dims a mark while another one is emphasised. No animation under Reduce Motion.
  func chartKitDimmed(_ isDimmed: Bool, reduceMotion: Bool) -> some View {
    opacity(isDimmed ? 0.4 : 1)
      .animation(AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion), value: isDimmed)
  }
}

// MARK: Frame

/// The frame every part-C1 view sits in. It shows the empty state when
/// nothing has a price, otherwise the chart (given the size it may use) with
/// the unpriced note underneath, and describes the whole chart to VoiceOver.
struct ChartKitFrame<Content: View>: View {
  var data: ChartKitData
  var density: PortfolioChartDensity
  var viewName: String
  @ViewBuilder var content: (CGSize) -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: density == .full ? 8 : 4) {
      if data.isEmpty {
        ChartKitEmptyState(unpricedCount: data.unpricedHoldingCount, density: density)
      } else {
        GeometryReader { proxy in
          content(proxy.size)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        if data.unpricedHoldingCount > 0 {
          ChartKitUnpricedNote(count: data.unpricedHoldingCount, density: density)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(data.summary(viewName: viewName))
  }
}

struct ChartKitEmptyState: View {
  @Environment(\.atlasTheme) private var tokens
  var unpricedCount: Int
  var density: PortfolioChartDensity

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "chart.pie")
        .font(.system(size: density == .full ? 26 : 18, weight: .regular))
        .foregroundStyle(tokens.color(.ink3))
        .accessibilityHidden(true)
      Text(ChartKitFormat.emptyTitle)
        .font(tokens.chartKitBodyFont(density == .full ? 14 : 12))
        .foregroundStyle(tokens.color(.ink2))
        .multilineTextAlignment(.center)
      if unpricedCount > 0 {
        ChartKitUnpricedNote(count: unpricedCount, density: density, alignment: .center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// "3 holdings have no price and aren't in the total." The sentence is the
/// first choice; a short form replaces it where the sentence does not fit.
struct ChartKitUnpricedNote: View {
  @Environment(\.atlasTheme) private var tokens
  var count: Int
  var density: PortfolioChartDensity
  var alignment: Alignment = .leading

  var body: some View {
    let size: CGFloat = density == .full ? 12 : 11
    ViewThatFits(in: .horizontal) {
      Text(ChartKitFormat.unpricedNote(count: count)).fixedSize()
      Text(ChartKitFormat.unpricedShort(count: count)).fixedSize()
      Color.clear.frame(width: 0, height: 0)
    }
    .font(tokens.chartKitBodyFont(size))
    .foregroundStyle(tokens.color(.ink2))
    .lineLimit(1)
    .frame(maxWidth: .infinity, alignment: alignment)
    .accessibilityLabel(ChartKitFormat.unpricedNote(count: count))
  }
}

// MARK: Legend

/// A wrapping row layout for compact legends. Deterministic: items keep their
/// order and wrap at the proposed width.
struct ChartKitFlowLayout: Layout {
  var spacing: CGFloat = 14
  var lineSpacing: CGFloat = 5

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let arranged = arrange(width: bounds.width, subviews: subviews)
    for (index, frame) in arranged.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      var size = subview.sizeThatFits(.unspecified)
      if width.isFinite { size.width = min(size.width, width) }
      if x > 0, x + size.width > width {
        widest = max(widest, x - spacing)
        x = 0
        y += rowHeight + lineSpacing
        rowHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    widest = max(widest, x - spacing)
    return (CGSize(width: max(0, widest), height: y + rowHeight), frames)
  }
}

/// The swatch beside a legend entry: the block's shape in miniature.
struct ChartKitSwatch: View {
  @Environment(\.atlasTheme) private var tokens
  var color: AtlasRGB
  var size: CGFloat = 10

  var body: some View {
    let style = ChartKitBlockStyle(tokens: tokens)
    let shape = RoundedRectangle(
      cornerRadius: min(style.cornerRadius, size * 0.3), style: .continuous)
    shape
      .fill(color.color)
      .blendMode(style.multiplies ? .multiply : .normal)
      .overlay {
        if style.borderWidth > 0 {
          shape.strokeBorder(style.borderColor, lineWidth: min(style.borderWidth, 1.5))
        }
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// A legend over slices. `.column` is a table (swatch, name, share, optionally
/// value) for a side panel; `.flow` is a wrapping row of swatch, name and
/// share for under a chart. Entries highlight their slice on hover and select
/// on tap, like the marks they describe; VoiceOver already reads the marks, so
/// the legend is hidden from it.
struct ChartKitLegend: View {
  enum Layout {
    case column
    case flow
  }

  @Environment(\.atlasTheme) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var slices: [ChartKitSlice]
  var layout: Layout = .column
  var showsValue = true
  var fontSize: CGFloat = 12
  /// The colours the chart drew its slices in (`chartKitColors(for:)`), by id.
  var colors: [String: AtlasRGB] = [:]
  /// Colour of an entry; defaults to the slice's own colour. Receives the
  /// slice, its parent (for a second-level entry) and its index among siblings.
  var color: ((ChartKitSlice, ChartKitSlice?, Int) -> AtlasRGB)?
  /// Shows each slice's children, indented, under it.
  var showsChildren = false
  @Binding var state: ChartKitInteractionState
  var onSelect: (PortfolioChartSelection) -> Void

  var body: some View {
    Group {
      switch layout {
      case .column:
        VStack(alignment: .leading, spacing: fontSize * 0.5) {
          ForEach(slices) { slice in
            columnRow(slice, parent: nil, index: 0)
            if showsChildren {
              ForEach(Array(slice.children.filter { $0.valueUsd > 0 }.enumerated()), id: \.element.id) {
                index, child in
                columnRow(child, parent: slice, index: index)
              }
            }
          }
        }
      case .flow:
        ChartKitFlowLayout(spacing: 14, lineSpacing: 4) {
          ForEach(slices) { slice in flowItem(slice) }
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func rgb(_ slice: ChartKitSlice, _ parent: ChartKitSlice?, _ index: Int) -> AtlasRGB {
    color?(slice, parent, index) ?? colors[slice.id] ?? tokens.chartKitRGB(slice.color)
  }

  private func columnRow(_ slice: ChartKitSlice, parent: ChartKitSlice?, index: Int) -> some View {
    let isChild = parent != nil
    let size = isChild ? fontSize - 1 : fontSize
    return HStack(spacing: 8) {
      ChartKitSwatch(color: rgb(slice, parent, index), size: isChild ? 8 : 10)
      Text(slice.label)
        .font(tokens.chartKitLabelFont(size, weight: isChild ? .regular : .semibold))
        .foregroundStyle(tokens.color(isChild ? .ink2 : .ink))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 6)
      Text(ChartKitFormat.percent(isChild ? slice.shareOfParent : slice.share))
        .font(tokens.chartKitNumberFont(size))
        .foregroundStyle(tokens.color(.ink2))
        .lineLimit(1)
        .fixedSize()
      // The value column is the first thing to go when text is very large.
      if showsValue, !dynamicTypeSize.isAccessibilitySize {
        Text(ChartKitFormat.usd(slice.valueUsd))
          .font(tokens.chartKitNumberFont(size))
          .foregroundStyle(tokens.color(isChild ? .ink2 : .ink))
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: size * 5.2, alignment: .trailing)
      }
    }
    .padding(.leading, isChild ? 18 : 0)
    .padding(.vertical, 1)
    .opacity(state.isDimmed(slice.id) ? 0.45 : 1)
    .animation(
      AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
      value: state.isDimmed(slice.id)
    )
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active: if state.hoveredID != slice.id { state.hoveredID = slice.id }
      case .ended: if state.hoveredID == slice.id { state.hoveredID = nil }
      }
    }
    .onTapGesture {
      guard let selection = slice.selection else { return }
      state.selectedID = slice.id
      onSelect(selection)
    }
  }

  private func flowItem(_ slice: ChartKitSlice) -> some View {
    HStack(spacing: 5) {
      ChartKitSwatch(color: rgb(slice, nil, 0), size: 9)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(slice.label)
          .font(tokens.chartKitLabelFont(fontSize))
        Text(ChartKitFormat.percent(slice.share))
          .font(tokens.chartKitNumberFont(fontSize))
      }
      .foregroundStyle(tokens.color(.ink2))
      .lineLimit(1)
    }
    .opacity(state.isDimmed(slice.id) ? 0.45 : 1)
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active: if state.hoveredID != slice.id { state.hoveredID = slice.id }
      case .ended: if state.hoveredID == slice.id { state.hoveredID = nil }
      }
    }
    .onTapGesture {
      guard let selection = slice.selection else { return }
      state.selectedID = slice.id
      onSelect(selection)
    }
  }
}

// MARK: Graphic and legend

/// A square graphic (ring, waffle, sunburst) with its legend: side by side when
/// the frame is wide enough, the legend under the graphic when it is not. The
/// graphic is given the side it may use.
struct ChartKitGraphicLayout<Graphic: View, Legend: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var size: CGSize
  var density: PortfolioChartDensity
  /// Width the legend would like beside the graphic.
  var legendWidth: CGFloat
  @ViewBuilder var graphic: (CGFloat) -> Graphic
  @ViewBuilder var legend: () -> Legend

  var body: some View {
    let spacing: CGFloat = density == .full ? 28 : 16
    let sideBySideSide = min(size.height, size.width - legendWidth - spacing)
    let minimumSide: CGFloat = density == .full ? 150 : 110
    // At the accessibility text sizes the legend needs the whole width.
    if sideBySideSide >= minimumSide, !dynamicTypeSize.isAccessibilitySize {
      HStack(alignment: .center, spacing: spacing) {
        graphic(sideBySideSide).frame(width: sideBySideSide, height: sideBySideSide)
        legend().frame(maxWidth: legendWidth + 40, alignment: .leading)
      }
      .frame(width: size.width, height: size.height, alignment: .center)
    } else {
      let side = max(0, min(size.width, size.height * 0.64))
      VStack(alignment: .leading, spacing: 10) {
        graphic(side).frame(width: side, height: side).frame(maxWidth: .infinity)
        legend()
        Spacer(minLength: 0)
      }
      .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
  }
}

/// The figure and caption in the hole of a ring: the largest size that fits
/// the hole, then smaller ones, then the figure alone, then nothing.
struct ChartKitRingCenter: View {
  @Environment(\.atlasTheme) private var tokens

  var title: String
  var caption: String?
  /// Diameter of the hole the text sits in.
  var diameter: CGFloat

  var body: some View {
    ViewThatFits {
      stack(26)
      stack(22)
      stack(18)
      stack(15)
      stack(12)
      Color.clear.frame(width: 0, height: 0)
    }
    .frame(width: diameter * 0.8, height: diameter * 0.62)
    .accessibilityHidden(true)
  }

  private func stack(_ size: CGFloat) -> some View {
    VStack(spacing: 2) {
      Text(title)
        .font(tokens.chartKitDisplayFont(size))
        .foregroundStyle(tokens.color(.ink))
        .lineLimit(1)
        .fixedSize()
      if let caption {
        Text(caption)
          // Body face: the caption can carry a share, and a label face may not
          // draw digits and percent signs well (see `figureFaceMisleads`).
          .font(tokens.chartKitBodyFont(max(10.5, size * 0.46)))
          .foregroundStyle(tokens.color(.ink2))
          .lineLimit(1)
          .fixedSize()
      }
    }
  }
}
