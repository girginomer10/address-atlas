import AddressAtlasCore
import SwiftUI

// Pieces shared by the coin widgets (state strip, unlock timeline, amount
// history, change, custody): resolving which coin a widget shows, the
// proportional segment bar, and the swatch + name + amount + value row.
//
// Coin widgets take a `PortfolioChartInput` whose `coinKey` names the coin
// (`CoinIdentity.key`). When `coinKey` is nil they show the largest coin in
// `input.holdings`. The widgets that need no history (state strip, unlock
// timeline, custody) also accept a `CoinSummary` directly.

// MARK: - Resolving the coin

enum CoinWidgetResolver {
  /// The coin a widget shows: the explicit summary, else `input.coinKey`
  /// (normalised), else the largest coin in the holdings.
  static func summary(for input: PortfolioChartInput, override: CoinSummary? = nil) -> CoinSummary? {
    if let override { return override }
    guard let key = coinKey(for: input) else { return nil }
    return PortfolioAnalytics.coinSummary(input.holdings, coin: key)
  }

  /// `CoinIdentity.key` of the coin to show; nil when there is none.
  static func coinKey(for input: PortfolioChartInput, override: CoinSummary? = nil) -> String? {
    if let override { return override.id }
    if let key = input.coinKey, !key.trimmingCharacters(in: .whitespaces).isEmpty {
      return CoinIdentity.key(forSymbol: key)
    }
    return PortfolioAnalytics.coinSummaries(input.holdings).first?.id
  }

  /// The holding state's chart colour.
  static func stateColor(_ state: HoldingState, tokens: AtlasThemeTokens) -> AtlasRGB {
    guard let themed = AtlasHoldingState(rawValue: state.rawValue) else {
      return tokens.chart.categorical(at: 0)
    }
    return tokens.chart.state(themed)
  }

  /// Amount and value of a state, as "280 ATOM" and "$1,904.00"; the value is
  /// "No price" when the coin has no price at all.
  static func valueText(_ valueUsd: Double, priced: Bool) -> String {
    priced ? HistoryChartFormat.usd(valueUsd, cents: true) : "No price"
  }
}

// MARK: - Segment bar

struct CoinWidgetSegment: Identifiable, Equatable {
  let id: String
  /// Relative size; segments with a non-positive weight are not drawn.
  let weight: Double
  let color: AtlasRGB
  /// Draw diagonal hatching, for "not known" shares.
  var hatched = false
  /// Spoken by VoiceOver.
  let label: String
}

enum CoinWidgetSegmentLayout {
  /// Segment widths for `weights` across `total` points with `gap` between
  /// neighbours. Every positive weight gets at least `minimum` points so a
  /// sliver stays visible; the widths and gaps add up to `total`.
  static func widths(weights: [Double], total: CGFloat, gap: CGFloat, minimum: CGFloat) -> [CGFloat] {
    let positive = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    let count = positive.filter { $0 > 0 }.count
    guard count > 0, total > 0 else { return positive.map { _ in 0 } }
    let available = max(0, total - gap * CGFloat(count - 1))
    var pinned = Set<Int>()
    var widths = positive.map { _ in CGFloat(0) }
    // Segments below the minimum are pinned to it; the rest share what is left.
    for _ in 0..<(count + 1) {
      let remaining = available - minimum * CGFloat(pinned.count)
      let freeWeight = positive.enumerated().filter { $0.element > 0 && !pinned.contains($0.offset) }
        .map(\.element).reduce(0, +)
      var changed = false
      for (index, weight) in positive.enumerated() where weight > 0 {
        if pinned.contains(index) {
          widths[index] = minimum
        } else {
          widths[index] = freeWeight > 0 ? max(0, remaining) * CGFloat(weight / freeWeight) : 0
          if widths[index] < minimum {
            pinned.insert(index)
            changed = true
          }
        }
      }
      if !changed { break }
    }
    // If the minimums alone overflow, scale everything down evenly.
    let sum = widths.reduce(0, +)
    if sum > available, sum > 0 {
      widths = widths.map { $0 * available / sum }
    }
    return widths
  }

  /// Left edges for `widths` (zero-width entries take no gap).
  static func origins(widths: [CGFloat], gap: CGFloat) -> [CGFloat] {
    var origins: [CGFloat] = []
    var x: CGFloat = 0
    for width in widths {
      origins.append(x)
      if width > 0 { x += width + gap }
    }
    return origins
  }
}

/// A one-line proportional bar of coloured segments, with hover and tap.
struct CoinWidgetSegmentBar: View {
  @Environment(\.atlasTheme) private var tokens
  let segments: [CoinWidgetSegment]
  var height: CGFloat = 30
  var density: PortfolioChartDensity = .full
  var active: Binding<String?>
  var onActivate: (String) -> Void = { _ in }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: density)
    let gap: CGFloat = style.markBorderWidth > 0 ? 4 : 3
    let weights = segments.map(\.weight)
    let activeID = active.wrappedValue
    GeometryReader { proxy in
      let width = proxy.size.width
      let widths = CoinWidgetSegmentLayout.widths(
        weights: weights, total: width, gap: gap, minimum: 4)
      let origins = CoinWidgetSegmentLayout.origins(widths: widths, gap: gap)
      Canvas { context, size in

        for (index, segment) in segments.enumerated() where widths[index] > 0 {
          let rect = CGRect(x: origins[index], y: 0, width: widths[index], height: size.height)
          let radius = min(style.blockRadius(for: min(rect.width, rect.height)), rect.width / 2)
          let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
          let dimmed = activeID != nil && activeID != segment.id
          context.opacity = dimmed ? 0.5 : 1
          context.fill(path, with: .color(segment.color.color))
          if segment.hatched {
            var hatch = context
            hatch.clip(to: path)
            var lines = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
              lines.move(to: CGPoint(x: x, y: rect.maxY))
              lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
              x += 7
            }
            hatch.stroke(
              lines, with: .color(style.ink(on: segment.color).opacity(0.45)), lineWidth: 1.5)
          }
          if style.markBorderWidth > 0 {
            context.stroke(path, with: .color(style.outline), lineWidth: style.markBorderWidth)
          }
          if activeID == segment.id {
            context.stroke(path, with: .color(style.ink), lineWidth: 2)
          }
        }
      }
      .contentShape(Rectangle())
      .historyPointer(
        active: active,
        hitTest: { point in
          for (index, segment) in segments.enumerated() where widths[index] > 0 {
            let lower = origins[index] - gap / 2
            let upper = origins[index] + widths[index] + gap / 2
            if point.x >= lower, point.x <= upper { return segment.id }
          }
          return nil
        },
        onActivate: onActivate
      )
      .accessibilityChildren {
        ForEach(segments.filter { $0.weight > 0 }) { segment in
          Color.clear
            .accessibilityLabel(segment.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onActivate(segment.id) }
        }
      }
    }
    .frame(height: height)
  }
}

// MARK: - Row

/// Swatch, name (with an optional second line), amount and value. Hovering
/// highlights it; tapping runs `action`.
struct CoinWidgetRow: View {
  @Environment(\.atlasTheme) private var tokens
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let swatch: AtlasRGB
  var hatched = false
  let title: String
  var detail: String?
  let amount: String
  let value: String
  var isActive = false
  var density: PortfolioChartDensity = .full
  var onHover: (Bool) -> Void = { _ in }
  var action: (() -> Void)?

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: density)
    let stacked = dynamicTypeSize.isAccessibilitySize
    let content = Group {
      if stacked {
        VStack(alignment: .leading, spacing: 2) {
          titleBlock(style)
          Text(verbatim: "\(amount) \u{00B7} \(value)")
            .font(style.numberFont(12, relativeTo: .footnote))
            .foregroundStyle(style.ink2)
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          titleBlock(style)
          Spacer(minLength: 8)
          Text(verbatim: amount)
            .font(style.numberFont(12, relativeTo: .footnote))
            .foregroundStyle(style.ink)
            .lineLimit(1)
          Text(verbatim: value)
            .font(style.numberFont(12, relativeTo: .footnote))
            .foregroundStyle(style.ink2)
            .lineLimit(1)
            .frame(minWidth: 70, alignment: .trailing)
        }
      }
    }
    content
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: style.tokens.shape.radiusSmall, style: .continuous)
          .fill(isActive ? style.surfaceMuted : Color.clear)
      )
      .contentShape(Rectangle())
      .onHover { onHover($0) }
      .onTapGesture { action?() }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(title), \(amount), \(value)" + (detail.map { ", \($0)" } ?? ""))
      .accessibilityAddTraits(action == nil ? [] : .isButton)
      .accessibilityAction { action?() }
  }

  private func titleBlock(_ style: HistoryChartStyle) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(swatch.color)
        .frame(width: 10, height: 10)
        .overlay {
          if hatched {
            // The same diagonal hatching as the bar segment.
            Canvas { context, size in
              var lines = Path()
              var x = -size.height
              while x < size.width {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3.5
              }
              context.stroke(lines, with: .color(style.ink(on: swatch).opacity(0.5)), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
          } else if style.markBorderWidth > 0 {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .stroke(style.outline, lineWidth: 1)
          }
        }
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: title)
          .font(style.bodyFont)
          .foregroundStyle(style.ink)
          .lineLimit(1)
        if let detail {
          Text(verbatim: detail)
            .font(style.smallFont)
            .foregroundStyle(style.ink3)
            .lineLimit(1)
        }
      }
    }
  }
}
