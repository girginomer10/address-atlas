import AddressAtlasCore
import Foundation
import SwiftUI

// Shared helpers for the history-oriented chart views (flow, over time, what
// changed, atlas map, slope, concentration, calendar) and the coin widgets
// (state strip, unlock timeline, amount history, change, custody).
//
// Everything here is prefixed `History` so it cannot collide with another
// chart helper layer. The views draw with `Canvas` and measured text, so
// labels adapt to the theme's fonts and to Dynamic Type instead of assuming a
// size, and every picture has an accessibility summary and per-element
// children for VoiceOver.

// MARK: - Formatting

enum HistoryChartFormat {
  static var locale: Locale { AtlasFormatting.locale }

  /// `$49,123`. Cents only when asked for, or below $100.
  static func usd(_ value: Double, cents: Bool? = nil) -> String {
    guard value.isFinite else { return "$0" }
    let showsCents = cents ?? (abs(value) < 100 && value != value.rounded())
    return value.formatted(
      .currency(code: "USD")
        .precision(.fractionLength(showsCents ? 2 : 0))
        .locale(locale))
  }

  /// `$49K`, `$1.2M`, `$830`: for axis ticks and small labels.
  static func usdCompact(_ value: Double) -> String {
    guard value.isFinite else { return "$0" }
    let magnitude = abs(value)
    let sign = value < 0 ? "\u{2212}" : ""
    let scaled: Double
    let suffix: String
    switch magnitude {
    case 1_000_000_000...: (scaled, suffix) = (magnitude / 1_000_000_000, "B")
    case 1_000_000...: (scaled, suffix) = (magnitude / 1_000_000, "M")
    case 1_000...: (scaled, suffix) = (magnitude / 1_000, "K")
    default: (scaled, suffix) = (magnitude, "")
    }
    let digits = suffix.isEmpty || scaled >= 10 ? 0 : 1
    let number = scaled.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    return sign + "$" + number + suffix
  }

  /// `+$410` or `−$46` (a true minus sign), `$0` for zero.
  static func signedUsd(_ value: Double, cents: Bool? = nil) -> String {
    guard value.isFinite, value != 0 else { return usd(0) }
    let magnitude = usd(abs(value), cents: cents)
    return (value > 0 ? "+" : "\u{2212}") + magnitude
  }

  /// `57%`, `<1%` for a positive share under one percent.
  static func percent(_ fraction: Double) -> String {
    guard fraction.isFinite, fraction > 0 else { return "0%" }
    if fraction < 0.005 { return "<1%" }
    return fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
  }

  /// `+0.9%` or `−1.4%`, with one decimal.
  static func signedPercent(_ fraction: Double) -> String {
    guard fraction.isFinite, abs(fraction) >= 0.0005 else { return "0%" }
    let body = abs(fraction).formatted(.percent.precision(.fractionLength(1)).locale(locale))
    return (fraction > 0 ? "+" : "\u{2212}") + body
  }

  /// A coin amount without noise: `24.79`, `0.0094`, `1,204`.
  static func amount(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    let magnitude = abs(value)
    let text: String
    if magnitude == 0 {
      text = "0"
    } else if magnitude < 1 {
      text = magnitude.formatted(
        .number.precision(.significantDigits(1...5)).locale(locale))
    } else if magnitude < 1000 {
      text = magnitude.formatted(.number.precision(.fractionLength(0...4)).locale(locale))
    } else {
      text = magnitude.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }
    return value < 0 ? "\u{2212}" + text : text
  }

  static func signedAmount(_ value: Double) -> String {
    guard value.isFinite, value != 0 else { return "0" }
    return (value > 0 ? "+" : "") + amount(value)
  }

  /// `4 Nov` (or `Nov 4`, by locale).
  static func day(_ date: Date, timeZone: TimeZone) -> String {
    date.formatted(
      Date.FormatStyle(timeZone: timeZone).day().month(.abbreviated).locale(locale))
  }

  /// `Tue 4 Nov`.
  static func dayWithWeekday(_ date: Date, timeZone: TimeZone) -> String {
    date.formatted(
      Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)
        .locale(locale))
  }

  /// `4 Nov 2026`.
  static func fullDay(_ date: Date, timeZone: TimeZone) -> String {
    date.formatted(
      Date.FormatStyle(timeZone: timeZone).day().month(.abbreviated).year().locale(locale))
  }

  /// `Nov`.
  static func month(_ date: Date, timeZone: TimeZone) -> String {
    date.formatted(Date.FormatStyle(timeZone: timeZone).month(.abbreviated).locale(locale))
  }

  /// "1 coin", "2 coins".
  static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
    "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
  }
}

// MARK: - Style

/// Fonts, ink and sizes for one chart in one theme. Built from the theme
/// tokens in the environment, so nothing here is a literal colour.
struct HistoryChartStyle {
  let tokens: AtlasThemeTokens
  let density: PortfolioChartDensity

  var isCompact: Bool { density == .compact }

  // Fonts. `relativeTo` lets iOS scale them with Dynamic Type.
  var captionFont: Font {
    tokens.font(.label, size: isCompact ? 9.5 : 11, relativeTo: .caption, weight: nil)
  }
  var smallFont: Font {
    tokens.font(.label, size: isCompact ? 9 : 10, relativeTo: .caption2, weight: nil)
  }
  var bodyFont: Font {
    tokens.font(.body, size: isCompact ? 11 : 13, relativeTo: .footnote, weight: nil)
  }
  var strongFont: Font {
    tokens.font(.body, size: isCompact ? 11 : 13, relativeTo: .footnote, weight: .semibold)
  }
  func numberFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
    tokens.font(.number, size: size, relativeTo: style, weight: nil)
  }
  func displayFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
    tokens.font(.display, size: size, relativeTo: style, weight: nil)
  }

  // Ink.
  var ink: Color { tokens.color(.ink) }
  var ink2: Color { tokens.color(.ink2) }
  var ink3: Color { tokens.color(.ink3) }
  var rule: Color { tokens.color(.rule) }
  var ruleSoft: Color { tokens.color(.ruleSoft) }
  var surface: Color { tokens.color(.surface) }
  var surfaceMuted: Color { tokens.color(.surfaceMuted) }
  var canvas: Color { tokens.color(.canvas) }
  var gain: Color { tokens.color(.gain) }
  var loss: Color { tokens.color(.loss) }
  var warning: Color { tokens.color(.warning) }
  var outline: Color { tokens.color(.outline) }

  /// Border width for marks that carry a theme border (hard-edged themes draw
  /// bolder block outlines than soft ones).
  var markBorderWidth: CGFloat {
    tokens.shape.hasBoldBorders ? (isCompact ? 1.5 : 2) : 0
  }

  /// Corner radius for blocks, scaled down for small blocks.
  func blockRadius(for side: CGFloat) -> CGFloat {
    min(tokens.shape.radiusSmall, max(0, side / 4))
  }

  /// Ink for text on a block of `background`: the theme's dark pastel ink when
  /// it reads, otherwise black or white.
  func ink(on background: AtlasRGB) -> Color {
    let pastel = tokens.palette.onPastel
    if pastel.contrast(with: background) >= 4.5 { return pastel.color }
    return background.readableInk.color
  }

  func rgbInk(on background: AtlasRGB) -> AtlasRGB {
    let pastel = tokens.palette.onPastel
    if pastel.contrast(with: background) >= 4.5 { return pastel }
    return background.readableInk
  }

  /// Series colour for one slice of a grouping.
  func color(grouping: PortfolioGrouping, key: String, label: String) -> AtlasRGB {
    switch grouping {
    case .asset:
      return tokens.chart.asset(label)
    case .network:
      return tokens.chart.network(key)
    case .state:
      if let state = AtlasHoldingState(rawValue: key) { return tokens.chart.state(state) }
    case .kind:
      if let kind = AtlasAssetKind(rawValue: key) { return tokens.chart.kind(kind) }
    case .source:
      break
    }
    let count = max(1, tokens.chart.categorical.count)
    return tokens.chart.categorical(
      at: Int(AtlasChartPalette.stableHash(key) % UInt64(count)))
  }

  /// Colours for a list of slices (largest first) in which no two share a
  /// colour, so stacked layers and lines stay separable. A slice keeps its
  /// theme colour unless an earlier slice already took it; then it steps
  /// through the categorical set.
  func distinctColors(grouping: PortfolioGrouping, keys: [(key: String, label: String)])
    -> [String: AtlasRGB]
  {
    var used: [AtlasRGB] = []
    var result: [String: AtlasRGB] = [:]
    let palette = tokens.chart.categorical
    for item in keys {
      var color = self.color(grouping: grouping, key: item.key, label: item.label)
      if used.contains(color), !palette.isEmpty {
        let start = Int(AtlasChartPalette.stableHash(item.key) % UInt64(palette.count))
        for offset in 0..<palette.count {
          let candidate = palette[(start + offset) % palette.count]
          if !used.contains(candidate) {
            color = candidate
            break
          }
        }
      }
      used.append(color)
      result[item.key] = color
    }
    return result
  }
}

// MARK: - Canvas text

extension GraphicsContext {
  /// Size of `string` in `font` on one line.
  func historyMeasure(_ string: String, font: Font) -> CGSize {
    resolve(Text(verbatim: string).font(font))
      .measure(in: CGSize(width: 4000, height: 1000))
  }

  /// Draws one line and returns the rectangle it covers.
  @discardableResult
  func historyDraw(
    _ string: String,
    font: Font,
    color: Color,
    at point: CGPoint,
    anchor: UnitPoint = .center
  ) -> CGRect {
    let resolved = resolve(Text(verbatim: string).font(font).foregroundStyle(color))
    let size = resolved.measure(in: CGSize(width: 4000, height: 1000))
    draw(resolved, at: point, anchor: anchor)
    let origin = CGPoint(
      x: point.x - size.width * anchor.x,
      y: point.y - size.height * anchor.y)
    return CGRect(origin: origin, size: size)
  }

  /// `string` cut with an ellipsis so it is at most `maxWidth` wide, or nil
  /// when not even a short form fits.
  func historyFit(_ string: String, font: Font, maxWidth: CGFloat, minimumCharacters: Int = 2)
    -> String?
  {
    guard maxWidth > 4 else { return nil }
    if historyMeasure(string, font: font).width <= maxWidth { return string }
    var characters = Array(string)
    while characters.count > minimumCharacters {
      characters.removeLast()
      let candidate = String(characters).trimmingCharacters(in: .whitespaces) + "\u{2026}"
      if historyMeasure(candidate, font: font).width <= maxWidth { return candidate }
    }
    return nil
  }
}

// MARK: - Tooltip

/// A tooltip drawn inside the canvas so it can be measured and clamped to the
/// chart. The first line is the title.
struct HistoryTooltip: Equatable {
  var lines: [String]
  /// Point the tooltip points at, in canvas coordinates.
  var anchor: CGPoint

  func draw(
    in context: inout GraphicsContext,
    bounds: CGRect,
    style: HistoryChartStyle
  ) {
    guard !lines.isEmpty else { return }
    let titleFont = style.strongFont
    let bodyFont = style.captionFont
    var sizes: [CGSize] = []
    for (index, line) in lines.enumerated() {
      sizes.append(context.historyMeasure(line, font: index == 0 ? titleFont : bodyFont))
    }
    let padding: CGFloat = 7
    let spacing: CGFloat = 2
    let width = min(bounds.width - 4, (sizes.map(\.width).max() ?? 0) + padding * 2)
    let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1))
      + padding * 2
    var originX = anchor.x + 12
    if originX + width > bounds.maxX - 2 { originX = anchor.x - 12 - width }
    originX = min(max(originX, bounds.minX + 2), max(bounds.minX + 2, bounds.maxX - width - 2))
    var originY = anchor.y - height - 8
    if originY < bounds.minY + 2 { originY = anchor.y + 14 }
    originY = min(max(originY, bounds.minY + 2), max(bounds.minY + 2, bounds.maxY - height - 2))
    let rect = CGRect(x: originX, y: originY, width: width, height: height)
    let shape = RoundedRectangle(
      cornerRadius: style.tokens.shape.radiusSmall, style: .continuous
    ).path(in: rect)
    if let offset = style.tokens.shape.cardShadowOffset, style.tokens.shape.hasHardShadows {
      let scale: CGFloat = style.isCompact ? 0.5 : 0.6
      context.fill(
        shape.offsetBy(dx: offset.width * scale, dy: offset.height * scale),
        with: .color(style.tokens.color(.shadow)))
    }
    context.fill(shape, with: .color(style.surface))
    context.stroke(
      shape, with: .color(style.outline),
      lineWidth: max(1, style.tokens.shape.cardBorderWidth * 0.6))
    var y = rect.minY + padding
    for (index, line) in lines.enumerated() {
      let font = index == 0 ? titleFont : bodyFont
      let color = index == 0 ? style.ink : style.ink2
      if let fitted = context.historyFit(line, font: font, maxWidth: width - padding * 2) {
        context.historyDraw(
          fitted, font: font, color: color, at: CGPoint(x: rect.minX + padding, y: y),
          anchor: .topLeading)
      }
      y += sizes[index].height + spacing
    }
  }
}

// MARK: - Pointer interaction

private struct HistoryPointerModifier<ID: Hashable>: ViewModifier {
  let hitTest: (CGPoint) -> ID?
  @Binding var active: ID?
  let onActivate: (ID) -> Void

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point): active = hitTest(point)
        case .ended: active = nil
        }
      }
      .gesture(
        SpatialTapGesture().onEnded { value in
          if let id = hitTest(value.location) {
            active = id
            onActivate(id)
          } else {
            active = nil
          }
        })
  }
}

extension View {
  /// Hover on macOS and tap on iOS: `active` follows the pointer (or the last
  /// tap), `onActivate` fires on click or tap.
  func historyPointer<ID: Hashable>(
    active: Binding<ID?>,
    hitTest: @escaping (CGPoint) -> ID?,
    onActivate: @escaping (ID) -> Void
  ) -> some View {
    modifier(HistoryPointerModifier(hitTest: hitTest, active: active, onActivate: onActivate))
  }
}

// MARK: - Layout cache

/// Remembers the last result of an expensive layout for one input. Used from
/// `body` through `@State`, so a hover redraw does not recompute the layout.
/// Main-actor only, because it lives inside a view.
@MainActor
final class HistoryLayoutCache<Key: Equatable, Value> {
  private var key: Key?
  private var value: Value?

  func value(for key: Key, compute: () -> Value) -> Value {
    if let existing = value, self.key == key { return existing }
    let fresh = compute()
    self.key = key
    value = fresh
    return fresh
  }
}

// MARK: - Messages and legends

/// A short plain message in the chart's place: empty states and "these scans
/// are not comparable" notices.
struct HistoryChartMessage: View {
  @Environment(\.atlasTheme) private var tokens
  let title: String
  var detail: String?
  var density: PortfolioChartDensity = .full

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: density)
    VStack(spacing: 6) {
      Text(verbatim: title)
        .font(style.strongFont)
        .foregroundStyle(style.ink)
        .multilineTextAlignment(.center)
      if let detail {
        Text(verbatim: detail)
          .font(style.captionFont)
          .foregroundStyle(style.ink2)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(density == .compact ? 10 : 20)
    .accessibilityElement(children: .combine)
  }
}

/// A wrapping row of swatch + label pairs.
struct HistoryLegendItem: Identifiable {
  let id: String
  let label: String
  let color: Color
}

struct HistoryLegend: View {
  @Environment(\.atlasTheme) private var tokens
  let items: [HistoryLegendItem]
  var density: PortfolioChartDensity = .full

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: density)
    HistoryFlowLayout(spacing: 12, lineSpacing: 4) {
      ForEach(items) { item in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(item.color)
            .frame(width: 9, height: 9)
            .overlay {
              if style.markBorderWidth > 0 {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                  .stroke(style.outline, lineWidth: 1)
              }
            }
          Text(verbatim: item.label)
            .font(style.captionFont)
            .foregroundStyle(style.ink2)
            .lineLimit(1)
        }
      }
    }
    .accessibilityHidden(true)
  }
}

/// Wraps its children onto new lines when they do not fit the width.
struct HistoryFlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    return arrange(maxWidth: maxWidth, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(maxWidth: bounds.width, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (
    frames: [CGRect], size: CGSize
  ) {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for subview in subviews {
      var size = subview.sizeThatFits(.unspecified)
      if maxWidth.isFinite { size.width = min(size.width, maxWidth) }
      if x > 0, x + size.width > maxWidth {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      usedWidth = max(usedWidth, x - spacing)
      lineHeight = max(lineHeight, size.height)
    }
    return (frames, CGSize(width: usedWidth, height: y + lineHeight))
  }
}

// MARK: - Chart numeric helpers

enum HistoryChartMath {
  /// A value as a finite number, `0` for NaN or infinity, so a bad input can
  /// never put NaN into a frame.
  static func finite(_ value: Double, fallback: Double = 0) -> Double {
    value.isFinite ? value : fallback
  }

  static func finite(_ value: CGFloat, fallback: CGFloat = 0) -> CGFloat {
    value.isFinite ? value : fallback
  }

  /// A "nice" axis maximum at or above `value`: 1, 2, 2.5, 5 times a power of
  /// ten.
  static func niceCeiling(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 1 }
    let exponent = floor(log10(value))
    let base = pow(10, exponent)
    let fraction = value / base
    let nice: Double
    switch fraction {
    case ...1: nice = 1
    case ...2: nice = 2
    case ...2.5: nice = 2.5
    case ...5: nice = 5
    default: nice = 10
    }
    return nice * base
  }

  /// Evenly spaced axis ticks from 0 to `maximum` (inclusive).
  static func ticks(maximum: Double, count: Int) -> [Double] {
    guard count > 0, maximum.isFinite, maximum > 0 else { return [0] }
    return (0...count).map { maximum * Double($0) / Double(count) }
  }

  /// Folds the smallest entries beyond `maximumCount - 1` into one remainder,
  /// keeping the largest first. `value` must be non-negative.
  static func foldingSmallest<T>(
    _ items: [T], keeping maximumCount: Int, value: (T) -> Double
  ) -> (kept: [T], folded: [T]) {
    guard maximumCount >= 1, items.count > maximumCount else { return (items, []) }
    let ordered = items.enumerated().sorted { lhs, rhs in
      let left = value(lhs.element)
      let right = value(rhs.element)
      if left != right { return left > right }
      return lhs.offset < rhs.offset
    }
    let kept = ordered.prefix(maximumCount - 1).sorted { $0.offset < $1.offset }.map(\.element)
    let folded = ordered.dropFirst(maximumCount - 1).sorted { $0.offset < $1.offset }.map(\.element)
    return (kept, folded)
  }
}

// MARK: - Run helpers

enum HistoryRuns {
  /// Runs oldest first, ties broken by id, so the order never depends on how
  /// the caller sorted them.
  static func ordered(_ runs: [ScanRunRecord]) -> [ScanRunRecord] {
    runs.sorted { lhs, rhs in
      if lhs.generatedAt != rhs.generatedAt { return lhs.generatedAt < rhs.generatedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// The most recent run and the latest earlier run that read the same
  /// sources, or nil when there are fewer than two runs. `comparable` is false
  /// when no earlier run shares sources with the latest, in which case
  /// `previous` is just the run before it.
  static func latestPair(
    _ runs: [ScanRunRecord],
    context: ScanSourceContext?
  ) -> (previous: ScanRunRecord, latest: ScanRunRecord, comparable: Bool)? {
    let sorted = ordered(runs)
    guard let latest = sorted.last, sorted.count >= 2 else { return nil }
    let earlier = sorted.dropLast()
    if let previous = earlier.last(where: {
      PortfolioAnalytics.runsShareSources($0, latest, context: context)
    }) {
      return (previous, latest, true)
    }
    return (earlier[earlier.count - 1], latest, false)
  }
}

// MARK: - Effects bar model

/// One signed amount in a "what moved the value" split: price, coins in or
/// out, and the part that is only a missing price.
struct HistoryEffect: Equatable, Identifiable {
  enum Kind: String { case price, amount, valuation }
  let kind: Kind
  let valueUsd: Double
  var id: String { kind.rawValue }

  var title: String {
    switch kind {
    case .price: "Price moves"
    case .amount: "Coins in or out"
    case .valuation: "Price missing in one scan"
    }
  }
}

enum HistoryEffects {
  /// Effects with a value, in a fixed order. The valuation gap is included only
  /// when it is not zero.
  static func effects(price: Double, amount: Double, valuationGap: Double = 0) -> [HistoryEffect] {
    var result = [
      HistoryEffect(kind: .price, valueUsd: HistoryChartMath.finite(price)),
      HistoryEffect(kind: .amount, valueUsd: HistoryChartMath.finite(amount)),
    ]
    if abs(valuationGap) > 0.005 {
      result.append(HistoryEffect(kind: .valuation, valueUsd: HistoryChartMath.finite(valuationGap)))
    }
    return result
  }
}

/// Draws signed effect rows: a label on the left, a bar growing from a shared
/// zero line to the right (gain) or left (loss), and the amount.
struct HistoryEffectsBar: View {
  @Environment(\.atlasTheme) private var tokens
  let effects: [HistoryEffect]
  var density: PortfolioChartDensity = .full

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: density)
    let maximum = max(effects.map { abs($0.valueUsd) }.max() ?? 0, 0.01)
    VStack(alignment: .leading, spacing: density == .compact ? 4 : 7) {
      ForEach(effects) { effect in
        HStack(spacing: 8) {
          Text(verbatim: effect.title)
            .font(style.captionFont)
            .foregroundStyle(style.ink2)
            .lineLimit(1)
            .frame(width: density == .compact ? 86 : 118, alignment: .leading)
          GeometryReader { proxy in
            let half = proxy.size.width / 2
            let length = half * CGFloat(abs(effect.valueUsd) / maximum)
            ZStack(alignment: .center) {
              Rectangle().fill(style.ruleSoft).frame(width: 1)
              Rectangle()
                .fill(effect.valueUsd >= 0 ? style.gain : style.loss)
                .frame(width: max(length, effect.valueUsd == 0 ? 0 : 2), height: proxy.size.height)
                .offset(x: effect.valueUsd >= 0 ? length / 2 : -length / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
          }
          .frame(height: density == .compact ? 10 : 14)
          Text(verbatim: HistoryChartFormat.signedUsd(effect.valueUsd))
            .font(style.numberFont(density == .compact ? 10.5 : 12, relativeTo: .caption))
            .foregroundStyle(
              effect.valueUsd == 0 ? style.ink2 : (effect.valueUsd > 0 ? style.gain : style.loss)
            )
            .lineLimit(1)
            .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(effect.title): \(HistoryChartFormat.signedUsd(effect.valueUsd))")
      }
    }
  }
}

// MARK: - Accessibility

extension View {
  /// Labels a drawn chart for VoiceOver and keeps its children reachable.
  func historyAccessibility(label: String) -> some View {
    accessibilityElement(children: .contain)
      .accessibilityLabel(label)
  }
}
