import AddressAtlasCore
import SwiftUI

// MARK: - Theme helpers for chart views
//
// Everything the part-C1 views need from the theme, in one place: slice
// colours, readable ink on a block, fonts, and the block style (corner radius,
// outline, hard shadow, overprint) read from `AtlasShape` and the chart
// palette. Views never test a theme id; they follow these values, so a new
// theme styled in the catalog gets the right blocks without changing a chart.

extension AtlasThemeTokens {
  /// The colour of a slice in this theme.
  func chartKitRGB(_ key: ChartKitColorKey) -> AtlasRGB {
    switch key {
    case .asset(let symbol):
      return chart.asset(symbol)
    case .network(let key, let label):
      // Networks are keyed by chain id; an exchange or manual venue may only
      // match by its name, so try both before falling back to a stable pick.
      let byKey = AtlasChartPalette.normalizedNetworkKey(key)
      if let color = chart.networks[byKey] { return color }
      let byLabel = AtlasChartPalette.normalizedNetworkKey(label)
      if let color = chart.networks[byLabel] { return color }
      return chart.network(key)
    case .state(let state):
      return chart.state(AtlasHoldingState(rawValue: state.rawValue) ?? .liquid)
    case .kind(let kind):
      return chart.kind(AtlasAssetKind(rawValue: kind.rawValue) ?? .token)
    case .index(let index):
      return chart.categorical(at: index)
    case .neutral:
      return palette.surfaceMuted.mixed(with: palette.ink3, amount: 0.35)
    }
  }

  /// The colour a chart assigned to `slice` (see `chartKitColors(for:)`), or its own.
  func chartKitRGB(_ slice: ChartKitSlice, in colors: [String: AtlasRGB]) -> AtlasRGB {
    colors[slice.id] ?? chartKitRGB(slice.color)
  }

  /// Colours for the slices of one chart, by slice id, with no two alike.
  ///
  /// Some themes reuse an ink on purpose (Riso prints Bitcoin and Cosmos in the
  /// same pink and Ether and USD Coin in the same blue), which is fine on a
  /// labelled block and useless in a legend. Within one chart the later of two
  /// slices that resolve to the same colour is given a lighter or darker tone of
  /// it. Order is the slices' order, so every view of the same data agrees.
  func chartKitColors(for slices: [ChartKitSlice]) -> [String: AtlasRGB] {
    var assigned: [String: AtlasRGB] = [:]
    var used: [AtlasRGB] = []
    func isTaken(_ colour: AtlasRGB) -> Bool {
      used.contains { other in
        abs(other.red - colour.red) + abs(other.green - colour.green)
          + abs(other.blue - colour.blue) < 0.06
      }
    }
    for slice in slices {
      let base = chartKitRGB(slice.color)
      var colour = base
      var step = 0
      while isTaken(colour), step < 5 {
        colour = base.chartKitTone(at: step)
        step += 1
      }
      assigned[slice.id] = colour
      used.append(colour)
    }
    return assigned
  }

  /// Ink for text on a block. The theme's pastel ink where it reads (4.5:1),
  /// black or white otherwise, so a block is never unreadable.
  func chartKitInk(on block: AtlasRGB) -> AtlasRGB {
    palette.onPastel.contrast(with: block) >= 4.5 ? palette.onPastel : block.readableInk
  }

  /// Small themed text: slice names, legend entries, axis-like captions.
  func chartKitLabelFont(_ size: CGFloat = 11, weight: Font.Weight? = nil) -> Font {
    font(.label, size: size, relativeTo: .caption, weight: weight)
  }

  /// A caption that may carry a count or an amount ("2 holdings"): the number face
  /// where the label face draws a five like an S (Silkscreen in the Pixel theme).
  func chartKitLabelFont(
    _ size: CGFloat = 11, weight: Font.Weight? = nil, figuresIn text: String
  ) -> Font {
    if typography.label.family.drawsFiveLikeS, text.contains(where: \.isNumber) {
      return chartKitNumberFont(size, weight: weight)
    }
    return chartKitLabelFont(size, weight: weight)
  }

  /// Figures: shares and values, tabular.
  func chartKitNumberFont(_ size: CGFloat = 12, weight: Font.Weight? = nil) -> Font {
    font(.number, size: size, relativeTo: .body, weight: weight)
  }

  /// A figure that stands alone, such as the value in a block: the display face
  /// from 16 points up (tabular digits only space its commas oddly at that size),
  /// the number face below.
  func chartKitFigureFont(_ size: CGFloat) -> Font {
    guard size >= 16 else { return chartKitNumberFont(size, weight: .bold) }
    return chartKitDisplayFont(size, relativeTo: .title3)
  }

  /// Running text inside a chart (empty state, notes).
  func chartKitBodyFont(_ size: CGFloat = 13) -> Font {
    font(.body, size: size, relativeTo: .callout)
  }

  /// Pixelify Sans, the Pixel theme's display face, draws its five like an S, so
  /// "$5,082" reads "$S,082". Where the display face is that font, large figures use
  /// the theme's number face (VT323 in the Pixel theme) and Pixelify Sans stays on names.
  private var displayFaceMisleadsFigures: Bool {
    typography.display.family == .pixelifySans
  }

  /// Large figures: the total in the middle of a ring.
  func chartKitDisplayFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
    if displayFaceMisleadsFigures { return font(.number, size: size, relativeTo: style) }
    return font(.display, size: size, relativeTo: style)
  }
}

extension AtlasRGB {
  /// The `index`th variant of a colour for the parts of a slice: lighter, then
  /// darker, then lighter still, so the parts read as belonging to the slice
  /// and still tell apart. Used for the second level of the map and the outer
  /// ring of rings in rings.
  func chartKitTone(at index: Int) -> AtlasRGB {
    let tones: [(AtlasRGB, Double)] = [
      (.white, 0.38), (.black, 0.12), (.white, 0.62), (.black, 0.26), (.white, 0.2),
    ]
    let tone = tones[((index % tones.count) + tones.count) % tones.count]
    return mixed(with: tone.0, amount: tone.1)
  }
}

/// How blocks (map blocks, bubbles, ring segments, strip segments, waffle
/// cells, list marks) are drawn in the current theme.
struct ChartKitBlockStyle: Equatable {
  /// Corner radius for a block big enough to carry it.
  let cornerRadius: CGFloat
  /// Outline width: 0 for the soft themes, the card border for the bold ones,
  /// and at least 1.5 under Increase Contrast.
  let borderWidth: CGFloat
  let borderColor: Color
  /// Hard offset shadow behind the block (Candy, Pixel), or nil.
  let shadowOffset: CGSize?
  let shadowColor: Color
  /// Colour of the highlight outline on the hovered or selected block.
  let highlightColor: Color
  /// Fills overprint like ink on paper (Riso).
  let multiplies: Bool
  /// Space between neighbouring blocks, enough for the outline and shadow.
  let gap: CGFloat

  init(tokens: AtlasThemeTokens) {
    let shape = tokens.shape
    let outline = shape.cardBorderWidth >= 1.5 ? shape.cardBorderWidth : 0
    cornerRadius = shape.radiusSmall
    borderWidth = max(outline, tokens.variant.isHighContrast ? 1.5 : 0)
    borderColor = tokens.color(.outline)
    shadowOffset = shape.controlShadowOffset
    shadowColor = tokens.color(.shadow)
    highlightColor = tokens.color(.ink)
    multiplies = tokens.chart.blendsWithMultiply
    gap = (shape.controlShadowOffset?.width ?? 0) + borderWidth + 3.5
  }

  /// The corner radius for a block of `size`: never more than a quarter of the
  /// short side, so small blocks stay blocks.
  func radius(for size: CGSize) -> CGFloat {
    min(cornerRadius, max(0, min(size.width, size.height) / 4))
  }

  /// The outline for a ring segment: the theme's, but thinner in compact charts
  /// and never more than a quarter of the arc's length, so a sliver stays a
  /// coloured sliver instead of turning into outline.
  func arcBorder(for arc: ChartKitArc, midRadius: CGFloat, compact: Bool) -> CGFloat {
    guard borderWidth > 0 else { return 0 }
    let length = CGFloat(arc.span) * midRadius
    return max(0, min(compact ? min(borderWidth, 1.5) : borderWidth, length / 4))
  }

  /// A hard shadow is dropped on small blocks, where it would swallow them.
  func shadow(for size: CGSize) -> CGSize? {
    guard let shadowOffset, min(size.width, size.height) >= 28 else { return nil }
    return shadowOffset
  }

  /// Room to keep free at the trailing and bottom edges of a chart so the
  /// shadow of the last blocks is not cut off.
  var shadowReserve: CGSize {
    guard let shadowOffset else { return .zero }
    return CGSize(
      width: max(0, shadowOffset.width - gap / 2), height: max(0, shadowOffset.height - gap / 2))
  }
}

/// A rounded block with the theme's fill, outline, hard shadow and overprint.
/// Used behind every block-like mark; text goes in an overlay.
struct ChartKitBlock: View {
  var style: ChartKitBlockStyle
  var fill: Color
  var size: CGSize
  var isActive = false
  var showsShadow = true

  var body: some View {
    let radius = style.radius(for: size)
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    ZStack {
      if showsShadow, let offset = style.shadow(for: size) {
        shape.fill(style.shadowColor).offset(x: offset.width, y: offset.height)
      }
      shape.fill(fill).blendMode(style.multiplies ? .multiply : .normal)
      if style.borderWidth > 0 {
        shape.strokeBorder(style.borderColor, lineWidth: style.borderWidth)
      }
      if isActive {
        shape.strokeBorder(style.highlightColor, lineWidth: max(2, style.borderWidth + 1))
      }
    }
    .accessibilityHidden(true)
  }
}
