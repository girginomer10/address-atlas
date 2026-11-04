import AddressAtlasCore
import SwiftUI

// Shared pieces of the Portfolio, Assets and Coin screens: coin rows, number
// formatting, the chart input builder and the chart frame.

// MARK: - Formatting

enum IOSNumber {
  /// A coin amount for a list: up to four decimals from 1 upward, six
  /// significant digits below 1, locale separators.
  static func amount(_ value: Double) -> String {
    guard value.isFinite else { return "–" }
    if value == 0 { return (0 as Double).formatted(.number.locale(AtlasFormatting.locale)) }
    if abs(value) >= 1 {
      return value.formatted(.number.precision(.fractionLength(0...4)).locale(AtlasFormatting.locale))
    }
    return value.formatted(
      .number.precision(.significantDigits(1...6)).locale(AtlasFormatting.locale))
  }

  /// Unit prices below a dollar keep their significant digits.
  static func price(_ value: Double) -> String {
    guard value.isFinite else { return "–" }
    if value > 0, value < 1 {
      return value.formatted(
        .currency(code: "USD").precision(.significantDigits(2...6)).locale(AtlasFormatting.locale))
    }
    return money(value)
  }

  /// "3 hours ago", or "just now" inside the first minute.
  static func relative(_ date: Date, now: Date = Date()) -> String {
    if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
    return date.formatted(
      Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)
        .locale(AtlasFormatting.locale))
  }

  /// "09:12" for today, "3 Nov" otherwise.
  static func since(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(
        Date.FormatStyle().hour().minute().locale(AtlasFormatting.locale))
    }
    return date.formatted(
      Date.FormatStyle().day().month(.abbreviated).locale(AtlasFormatting.locale))
  }

  static func count(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
  }
}

// MARK: - Chart input

@MainActor
extension AppState {
  /// The chart input for a screen: the shared builder, with wallet names
  /// edited after the scan applied to the holdings (the stored scans are
  /// never rewritten).
  func iosChartInput(
    grouping: PortfolioGrouping,
    coinKey: String? = nil,
    density: PortfolioChartDensity = .full,
    onSelect: @escaping (PortfolioChartSelection) -> Void = { _ in }
  ) -> PortfolioChartInput {
    var input = chartInput(
      grouping: grouping, coinKey: coinKey, density: density, onSelect: onSelect)
    input.holdings = AppState.applyingWalletLabels(to: input.holdings, wallets: document.wallets)
    return input
  }

  /// A readable label for a tapped chart slice.
  func sliceLabel(grouping: PortfolioGrouping, key: String) -> String {
    let slices = PortfolioAnalytics.breakdown(chartHoldings, by: grouping).slices
    if let slice = slices.first(where: { $0.key == key }) { return slice.label }
    if grouping == .state, let state = HoldingState(rawValue: key) { return state.displayName }
    if grouping == .kind, let kind = HoldingKind(rawValue: key) { return kind.displayName }
    return key
  }

  /// What a tap inside a chart does, shared by Portfolio and Coin detail:
  /// a coin opens its page, a slice narrows Assets, a scan opens History.
  func handleChartSelection(
    _ selection: PortfolioChartSelection,
    navigation: IOSNavigationModel,
    openCoin: Bool = true
  ) {
    clearTransientMessagesForNavigation()
    switch selection {
    case .coin(let key):
      if openCoin { navigation.openCoin(key) }
    case .slice(let grouping, let key):
      guard grouping != .asset else {
        if openCoin { navigation.openCoin(key) }
        return
      }
      navigation.openAssets(
        filter: IOSAssetsFilter(
          grouping: grouping, key: key, label: sliceLabel(grouping: grouping, key: key)))
    case .run(let id):
      navigation.openSnapshot(id)
    }
  }
}

// MARK: - Chart frame

/// Gives a chart the area it fills: charts take the space they are offered,
/// so the frame follows the width with a per-view proportion.
struct IOSChartCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var visualization: PortfolioVisualization
  var input: PortfolioChartInput

  /// Views that list every slice beside the graphic run out of height on a
  /// phone at full density; their compact form keeps the names and shares.
  static func density(for visualization: PortfolioVisualization) -> PortfolioChartDensity {
    switch visualization {
    case .ring, .grid, .ringsInRings: .compact
    default: .full
    }
  }

  /// Width over height.
  private var proportion: CGFloat {
    let base: CGFloat =
      switch visualization {
      case .map, .atlasMap, .bubbles: 1.0
      case .ring: 1.12
      case .ringsInRings: 1.12
      case .strip: 1.1
      case .grid: 1.12
      case .flow: 0.85
      case .list: 0.75
      case .overTime, .whatChanged: 0.9
      case .slope: 0.8
      case .concentration: 1.4
      case .calendar: 1.35
      }
    return dynamicTypeSize.isAccessibilitySize ? base * 0.78 : base
  }

  var body: some View {
    IOSCard(padding: 10) {
      Color.clear
        .aspectRatio(proportion, contentMode: .fit)
        .frame(maxHeight: 560)
        .overlay {
          PortfolioVisualizationView(visualization: visualization, input: input)
        }
    }
  }
}

// MARK: - Coin row

/// One coin: mark, symbol, what it is made of, value and share. Used by the
/// top holdings on Portfolio and by the Assets list.
struct IOSCoinRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var summary: CoinSummary
  /// Value the share is taken of; nil hides the share.
  var total: Double?

  /// "0.4120 BTC", then the states that are not plain balances ("300 staked"),
  /// otherwise where the coin is held, from most to least detailed so a
  /// narrow row can fall back to a shorter line.
  private var detailVariants: [String] {
    let amount = "\(IOSNumber.amount(summary.totalAmount)) \(summary.symbol)"
    let notes = summary.states.filter { $0.state != .liquid && $0.state != .onExchange }
    if !notes.isEmpty {
      let texts = notes.prefix(2).map {
        "\(IOSNumber.amount($0.amount)) \($0.state.displayName.lowercased())"
      }
      return [
        ([amount] + texts).joined(separator: " · "),
        "\(amount) · \(texts[0])",
        amount,
      ]
    }
    var places: [String] = []
    for location in summary.locations where !places.contains(location.networkLabel) {
      places.append(location.networkLabel)
    }
    guard let first = places.first else { return [amount] }
    if places.count == 1 { return ["\(amount) · \(first)", amount] }
    return [
      "\(amount) · \(places.prefix(2).joined(separator: ", "))\(places.count > 2 ? " +\(places.count - 2)" : "")",
      "\(amount) · \(first) +\(places.count - 1)",
      amount,
    ]
  }

  private var detail: String { detailVariants[0] }

  @ViewBuilder
  private var detailLine: some View {
    let variants = detailVariants
    ViewThatFits(in: .horizontal) {
      ForEach(Array(variants.enumerated()), id: \.offset) { _, text in
        Text(text).lineLimit(1)
      }
    }
    .font(AtlasTheme.font(.body, .subheadline))
    .foregroundStyle(AtlasTheme.ink3)
  }

  private var isUnpriced: Bool { summary.pricedAmount == 0 && summary.valueUsd == 0 }

  private var shareText: String? {
    guard let total, total > 0, summary.valueUsd > 0 else { return nil }
    return AtlasPercent.text(summary.valueUsd / total)
  }

  private var valueText: String { isUnpriced ? "No price" : money(summary.valueUsd) }

  private var accessibilityText: String {
    var parts = [summary.symbol, "amount \(IOSNumber.amount(summary.totalAmount))"]
    parts.append(isUnpriced ? "no USD price" : "value \(money(summary.valueUsd))")
    if let shareText { parts.append("\(shareText) of portfolio") }
    for state in summary.states where state.state != .liquid && state.state != .onExchange {
      parts.append("\(IOSNumber.amount(state.amount)) \(state.state.displayName.lowercased())")
    }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 12) {
            TokenMonogram(symbol: summary.symbol, size: 44)
            Text(summary.symbol)
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
              .foregroundStyle(AtlasTheme.ink)
          }
          Text(valueText)
            .font(AtlasTheme.font(.number, .body, weight: .semibold))
            .foregroundStyle(isUnpriced ? AtlasTheme.warning : AtlasTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
          Text(detail)
            .font(AtlasTheme.font(.body, .subheadline))
            .foregroundStyle(AtlasTheme.ink3)
          if let shareText {
            Text(shareText)
              .font(AtlasTheme.font(.number, .subheadline))
              .foregroundStyle(AtlasTheme.ink3)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 12) {
          TokenMonogram(symbol: summary.symbol, size: 40)
          VStack(alignment: .leading, spacing: 3) {
            Text(summary.symbol)
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
            detailLine
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .trailing, spacing: 3) {
            Text(valueText)
              .font(AtlasTheme.font(.number, .body, weight: .semibold))
              .foregroundStyle(isUnpriced ? AtlasTheme.warning : AtlasTheme.ink)
              .lineLimit(1)
            if let shareText {
              Text(shareText)
                .font(AtlasTheme.font(.number, .subheadline))
                .foregroundStyle(AtlasTheme.ink3)
                .lineLimit(1)
            }
          }
          .layoutPriority(1)
        }
      }
    }
    .frame(minHeight: 48)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }
}

/// A list of coin rows in one themed card; each row opens that coin.
struct IOSCoinList: View {
  var summaries: [CoinSummary]
  var total: Double?

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
        NavigationLink(value: IOSRoute.coin(summary.id)) {
          IOSCoinRow(summary: summary, total: total)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the coin.")
        .accessibilityIdentifier("coin-row-\(summary.symbol)")
        if index < summaries.count - 1 {
          Rectangle()
            .fill(AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft)
            .frame(height: AtlasTheme.shape.hasBoldBorders ? 1.5 : 1)
            .padding(.leading, 66)
            .accessibilityHidden(true)
        }
      }
    }
    .iosCardSurface()
  }
}
