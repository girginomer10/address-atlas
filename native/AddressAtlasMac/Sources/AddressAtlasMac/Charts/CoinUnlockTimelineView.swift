import AddressAtlasCore
import SwiftUI

/// When a coin's unbonding amounts become spendable: a line from the first scan
/// that showed the unbonding, through today, to each unlock date, with the
/// plain sentences underneath ("24.79 ATOM free on 16 Nov"). Networks that do
/// not report an unlock time (Solana) get a sentence instead of a date. When
/// nothing is unbonding the view says so in one line, so it is safe to place
/// unconditionally.
///
/// Coin widgets take `input.coinKey` (a `CoinIdentity.key`) and, when it is
/// nil, the largest coin in `input.holdings`. `now` is "today" on the line; the
/// screen passes the current date, tests pass a fixed one. `init(summary:)`
/// needs no history; without runs the start marker is left out. Tapping
/// anything reports `.slice(grouping: .state, key: "unbonding")`.
struct CoinUnlockTimelineView: View {
  let input: PortfolioChartInput
  let now: Date
  private let summaryOverride: CoinSummary?

  @Environment(\.atlasTheme) private var tokens
  @State private var hovered: String?

  init(input: PortfolioChartInput, now: Date = Date()) {
    self.input = input
    self.now = now
    self.summaryOverride = nil
  }

  /// For callers that already hold the coin's summary and need no history.
  init(
    summary: CoinSummary,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) {
    self.input = PortfolioChartInput(
      holdings: [], coinKey: summary.id, timeZone: timeZone, density: density, onSelect: onSelect)
    self.now = now
    self.summaryOverride = summary
  }

  var body: some View {
    let style = HistoryChartStyle(tokens: tokens, density: input.density)
    let compact = input.density == .compact
    if let summary = CoinWidgetResolver.summary(for: input, override: summaryOverride) {
      let model = CoinUnlockTimelineModel(
        summary: summary, runs: input.runs, now: now, timeZone: input.timeZone)
      if model.isEmpty {
        HistoryChartMessage(title: "Nothing is unbonding.", density: input.density)
      } else {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
          Text(verbatim: "\(model.amountText(model.totalAmount)) unbonding")
            .font(compact ? style.strongFont : style.displayFont(22, relativeTo: .title2))
            .foregroundStyle(style.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          if !model.dated.isEmpty {
            timeline(model: model, style: style)
          }
          if compact {
            compactSummary(model: model, style: style)
          } else {
            rows(model: model, style: style)
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .historyAccessibility(label: model.spokenSummary)
      }
    } else {
      HistoryChartMessage(
        title: emptyTitle, detail: "Scan again once it has been added.", density: input.density)
    }
  }

  // MARK: Timeline

  private enum Marker: Hashable {
    case start
    case today
    case unlock(Int)

    var id: String {
      switch self {
      case .start: "start"
      case .today: "today"
      case .unlock(let index): "unlock-\(index)"
      }
    }
  }

  private func timeline(model: CoinUnlockTimelineModel, style: HistoryChartStyle) -> some View {
    let compact = input.density == .compact
    let scale = CoinUnlockTimelineScale(model: model)
    let height: CGFloat = compact ? 58 : 82
    let lineY: CGFloat = compact ? 30 : 38
    let padding: CGFloat = 18
    let unbondingColor = CoinWidgetResolver.stateColor(.unbonding, tokens: tokens)
    return GeometryReader { proxy in
      let width = proxy.size.width
      let span = max(0, width - padding * 2)
      let x: (Date) -> CGFloat = { padding + CGFloat(scale.position(of: $0)) * span }
      let markers = markerPositions(model: model, x: x)
      Canvas { context, size in
        let line = Path { path in
          path.move(to: CGPoint(x: padding, y: lineY))
          path.addLine(to: CGPoint(x: size.width - padding, y: lineY))
        }
        context.stroke(
          line, with: .color(style.rule.opacity(0.55)),
          style: StrokeStyle(lineWidth: 3, lineCap: .round))
        if let seen = model.seenSince {
          let elapsed = Path { path in
            path.move(to: CGPoint(x: x(seen), y: lineY))
            path.addLine(to: CGPoint(x: x(model.now), y: lineY))
          }
          context.stroke(
            elapsed, with: .color(unbondingColor.color),
            style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        }
        // Markers.
        func circle(at point: CGPoint, radius: CGFloat) -> Path {
          Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        if let seen = model.seenSince {
          let path = circle(at: CGPoint(x: x(seen), y: lineY), radius: 5.5)
          context.fill(path, with: .color(unbondingColor.color))
          context.stroke(path, with: .color(style.outline), lineWidth: max(1, style.markBorderWidth))
        }
        for unlock in model.dated {
          let path = circle(at: CGPoint(x: x(unlock.date), y: lineY), radius: 7)
          context.fill(path, with: .color(unlock.hasPassed ? unbondingColor.color : style.surface))
          context.stroke(path, with: .color(unbondingColor.color), lineWidth: 2.5)
          if style.markBorderWidth > 0 {
            context.stroke(
              circle(at: CGPoint(x: x(unlock.date), y: lineY), radius: 8.5),
              with: .color(style.outline), lineWidth: style.markBorderWidth)
          }
        }
        let todayX = x(model.now)
        let tick = Path { path in
          path.move(to: CGPoint(x: todayX, y: lineY - 10))
          path.addLine(to: CGPoint(x: todayX, y: lineY + 10))
        }
        context.stroke(tick, with: .color(style.ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // Labels: today above; dates below, skipping any that would collide.
        let smallFont = style.captionFont
        var drawn: [CGRect] = []
        func place(_ text: String, at point: CGPoint, anchor: UnitPoint, color: Color) {
          let size = context.historyMeasure(text, font: smallFont)
          var originX = point.x - size.width * anchor.x
          originX = min(max(originX, 2), max(2, width - size.width - 2))
          let rect = CGRect(x: originX, y: point.y - size.height * anchor.y, width: size.width, height: size.height)
          let padded = rect.insetBy(dx: -6, dy: -2)
          guard !drawn.contains(where: { $0.intersects(padded) }) else { return }
          drawn.append(rect)
          context.historyDraw(
            text, font: smallFont, color: color, at: CGPoint(x: rect.minX, y: rect.minY),
            anchor: .topLeading)
        }
        place("today", at: CGPoint(x: todayX, y: lineY - 14), anchor: UnitPoint(x: 0.5, y: 1), color: style.ink)
        for unlock in model.dated {
          place(
            model.dayText(unlock.date), at: CGPoint(x: x(unlock.date), y: lineY + 15),
            anchor: UnitPoint(x: unlock.date >= model.now ? 0.8 : 0.5, y: 0), color: style.ink2)
        }
        if let seen = model.seenSince {
          place(
            model.dayText(seen), at: CGPoint(x: x(seen), y: lineY + 15),
            anchor: UnitPoint(x: 0.2, y: 0), color: style.ink3)
        }

        if let hovered, let marker = markers.first(where: { $0.0.id == hovered }) {
          HistoryTooltip(lines: tooltipLines(marker.0, model: model), anchor: CGPoint(x: marker.1, y: lineY))
            .draw(in: &context, bounds: CGRect(origin: .zero, size: size), style: style)
        }
      }
      .contentShape(Rectangle())
      .historyPointer(
        active: $hovered,
        hitTest: { point in
          guard abs(point.y - lineY) <= 22 else { return nil }
          let nearest = markers.min { abs($0.1 - point.x) < abs($1.1 - point.x) }
          guard let nearest, abs(nearest.1 - point.x) <= 16 else { return nil }
          return nearest.0.id
        },
        onActivate: { _ in selectUnbonding() }
      )
      .accessibilityHidden(true)
    }
    .frame(height: height)
  }

  private func markerPositions(
    model: CoinUnlockTimelineModel, x: (Date) -> CGFloat
  ) -> [(Marker, CGFloat)] {
    var result: [(Marker, CGFloat)] = []
    // Later entries win ties, so an unlock on today's tick is reachable.
    result.append((.today, x(model.now)))
    if let seen = model.seenSince { result.append((.start, x(seen))) }
    for unlock in model.dated { result.append((.unlock(unlock.index), x(unlock.date))) }
    return result
  }

  private func tooltipLines(_ marker: Marker, model: CoinUnlockTimelineModel) -> [String] {
    switch marker {
    case .start:
      return ["Seen unbonding", model.seenSince.map(model.dayText) ?? ""]
    case .today:
      return ["Today", model.dayText(model.now)]
    case .unlock(let index):
      guard let unlock = model.dated.first(where: { $0.index == index }) else { return [] }
      var lines = [model.sentence(for: unlock)]
      if let relative = model.relativeText(for: unlock) { lines.append(relative) }
      if model.priced { lines.append(HistoryChartFormat.usd(unlock.valueUsd, cents: true)) }
      return lines
    }
  }

  // MARK: Sentences

  private func rows(model: CoinUnlockTimelineModel, style: HistoryChartStyle) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.dated) { unlock in
        sentenceRow(
          model.sentence(for: unlock),
          secondary: secondary(for: unlock, model: model),
          style: style)
      }
      if let undated = model.undated {
        sentenceRow(model.sentence(for: undated), secondary: nil, style: style)
      }
      if let seen = model.seenSinceText {
        Text(verbatim: seen)
          .font(style.captionFont)
          .foregroundStyle(style.ink3)
          .padding(.leading, 20)
      }
    }
  }

  private func secondary(for unlock: CoinUnlockTimelineModel.DatedUnlock, model: CoinUnlockTimelineModel)
    -> String?
  {
    var parts: [String] = []
    if let relative = model.relativeText(for: unlock) { parts.append(relative.prefix(1).uppercased() + relative.dropFirst()) }
    if model.priced { parts.append(HistoryChartFormat.usd(unlock.valueUsd, cents: true)) }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
  }

  private func sentenceRow(_ text: String, secondary: String?, style: HistoryChartStyle) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .stroke(CoinWidgetResolver.stateColor(.unbonding, tokens: tokens).color, lineWidth: 2.5)
        .frame(width: 11, height: 11)
        .padding(.top, 3)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: text)
          .font(style.bodyFont)
          .foregroundStyle(style.ink)
          .fixedSize(horizontal: false, vertical: true)
        if let secondary {
          Text(verbatim: secondary)
            .font(style.captionFont)
            .foregroundStyle(style.ink3)
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { selectUnbonding() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text + (secondary.map { ", \($0)" } ?? ""))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { selectUnbonding() }
  }

  private func compactSummary(model: CoinUnlockTimelineModel, style: HistoryChartStyle) -> some View {
    let first =
      model.dated.first.map { model.sentence(for: $0) }
      ?? model.undated.map { model.sentence(for: $0) } ?? ""
    let extra = model.dated.count + (model.undated == nil ? 0 : 1) - 1
    return Text(verbatim: extra > 0 ? "\(first) and \(extra) more" : first)
      .font(style.captionFont)
      .foregroundStyle(style.ink2)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyTitle: String {
    if let key = input.coinKey, !key.isEmpty {
      return "No \(CoinIdentity.key(forSymbol: key)) in this scan."
    }
    return "No holdings to show."
  }

  private func selectUnbonding() {
    input.onSelect(.slice(grouping: .state, key: HoldingState.unbonding.rawValue))
  }
}
