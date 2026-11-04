import AddressAtlasCore
import SwiftUI

/// One coin across everything that holds it: value, amount and price, what
/// state it is in (liquid, staked, unbonding...), when unbonding funds free
/// up, a chart of where it sits, what changed, its history, who holds the
/// keys, and the holdings behind it with links to their explorers.
struct CoinDetailScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.atlasTheme) private var tokens
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 40
  @AppStorage("coin.visualization.v1") private var storedVisualization = PortfolioVisualization.ring.rawValue
  @AppStorage("coin.grouping.v1") private var storedGrouping = ""
  @State private var selectedHolding: TrackedAsset?
  var coinKey: String

  private static let groupings: [PortfolioGrouping] = [.network, .source, .state]
  private static let visualizations = PortfolioVisualization.allCases.filter(\.worksForSingleCoin)

  private var visualization: PortfolioVisualization {
    let value = PortfolioVisualization(rawValue: storedVisualization) ?? .ring
    return value.worksForSingleCoin ? value : .ring
  }

  /// The person's choice, else by state when the coin is in more than one
  /// state (so it does not show as one block), else by network.
  private var grouping: PortfolioGrouping {
    if let stored = PortfolioGrouping(rawValue: storedGrouping), Self.groupings.contains(stored) {
      return stored
    }
    let states = PortfolioAnalytics.coinSummary(holdings, coin: coinKey)?.states.count ?? 0
    return states > 1 ? .state : .network
  }

  private var holdings: [TrackedAsset] {
    AppState.applyingWalletLabels(
      to: state.chartHoldings.filter { CoinIdentity.key(for: $0) == coinKey },
      wallets: state.document.wallets
    )
    .sorted(by: Self.holdingOrder)
  }

  private static func holdingOrder(_ lhs: TrackedAsset, _ rhs: TrackedAsset) -> Bool {
    let left = lhs.pricingStatus == .priced ? lhs.valueUsd : -1
    let right = rhs.pricingStatus == .priced ? rhs.valueUsd : -1
    if left != right { return left > right }
    return lhs.id < rhs.id
  }

  var body: some View {
    let summary = PortfolioAnalytics.coinSummary(holdings, coin: coinKey)
    IOSPage(title: summary?.symbol ?? "Coin") {
      if let summary {
        header(summary)
        CoinStateStripView(summary: summary)
          .iosCoinCard()
        if !summary.unlocks.isEmpty {
          CoinUnlockTimelineView(input: input(.full))
            .iosCoinCard()
        }
        chartSection
        CoinChangeView(input: input(.full))
          .iosCoinCard()
        CoinAmountHistoryView(input: input(.full))
          .iosCoinCard()
        CoinCustodyView(summary: summary)
          .iosCoinCard()
        holdingsSection(summary)
      } else {
        IOSEmptyState(
          systemImage: "questionmark.circle",
          title: "Not in the latest scan",
          copy: "This coin is not in your latest scan. Scan to refresh, or go back to Assets.",
          actionTitle: "Go to Assets",
          action: { navigation.openAssets(filter: nil) })
      }
    }
    .sheet(item: $selectedHolding) { asset in
      AssetDetailSheet(asset: asset)
    }
  }

  private func input(_ density: PortfolioChartDensity) -> PortfolioChartInput {
    state.iosChartInput(
      grouping: grouping, coinKey: coinKey, density: density,
      onSelect: { selection in
        // Inside a coin only a scan can send the person elsewhere; the
        // slices of this coin's own charts stay on this page.
        if case .run = selection {
          state.handleChartSelection(selection, navigation: navigation, openCoin: false)
        }
      })
  }

  // MARK: Header

  private func header(_ summary: CoinSummary) -> some View {
    let hero = IOSHeroStyle.current(tokens)
    let unpriced = summary.pricedAmount == 0 && summary.valueUsd == 0
    return IOSCard(padding: 18, fill: hero.fill, ink: hero.ink) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          TokenMonogram(symbol: summary.symbol, size: 48)
          VStack(alignment: .leading, spacing: 2) {
            Text(summary.symbol)
              .font(AtlasTheme.font(.display, .title2))
              .foregroundStyle(hero.ink)
            Text(subtitle(summary))
              .font(AtlasTheme.font(.body, .subheadline))
              .foregroundStyle(hero.secondaryInk)
              .lineLimit(2)
          }
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        Text(unpriced ? "No price" : money(summary.valueUsd))
          .font(AtlasTheme.font(.number, size: valueSize, relativeTo: .largeTitle, weight: .heavy))
          .tracking(AtlasTheme.tracking(.display, size: valueSize))
          .foregroundStyle(unpriced ? AtlasTheme.warning : hero.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .accessibilityLabel(unpriced ? "No USD price" : "Value \(money(summary.valueUsd))")
        priceLine(summary, hero: hero)
        if summary.unpricedHoldingCount > 0 && !unpriced {
          Text(
            "\(IOSNumber.count(summary.unpricedHoldingCount, "holding")) \(summary.unpricedHoldingCount == 1 ? "has" : "have") no price and \(summary.unpricedHoldingCount == 1 ? "is" : "are") left out of the value."
          )
          .font(AtlasTheme.font(.body, .footnote))
          .foregroundStyle(hero.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func subtitle(_ summary: CoinSummary) -> String {
    let name =
      holdings.first { $0.symbol.caseInsensitiveCompare(summary.symbol) == .orderedSame }?
      .atlasDisplayName
    let amount = "\(IOSNumber.amount(summary.totalAmount)) \(summary.symbol)"
    return [amount, name].compactMap { $0 }.joined(separator: " · ")
  }

  @ViewBuilder
  private func priceLine(_ summary: CoinSummary, hero: IOSHeroStyle) -> some View {
    if let price = summary.priceUsd {
      let change = holdings.first(where: { $0.change24h != nil })?.change24h
      HStack(spacing: 8) {
        Text("Price \(IOSNumber.price(price))")
          .font(AtlasTheme.font(.number, .subheadline))
          .foregroundStyle(hero.secondaryInk)
        if let change, change.isFinite {
          Text("\(AtlasPercent.signedChange(change / 100)) today")
            .font(AtlasTheme.font(.number, .subheadline, weight: .semibold))
            .foregroundStyle(
              change >= 0.005 ? AtlasTheme.gain : (change <= -0.005 ? AtlasTheme.loss : hero.secondaryInk))
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  // MARK: Chart

  private var chartSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(Self.visualizations) { item in
            IOSChip(item.title, isSelected: item == visualization) {
              storedVisualization = item.rawValue
            }
          }
        }
        .padding(.horizontal, 16)
      }
      .padding(.horizontal, -16)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Chart view")
      if visualization.usesGrouping {
        HStack(spacing: 8) {
          ForEach(Self.groupings, id: \.self) { item in
            IOSChip(item.displayName == "Wallet or exchange" ? "Wallet" : item.displayName, isSelected: item == grouping) {
              storedGrouping = item.rawValue
            }
          }
          Spacer(minLength: 0)
        }
      }
      IOSChartCard(visualization: visualization, input: input(.full))
        .id("\(visualization.rawValue)-\(grouping.rawValue)")
    }
  }

  // MARK: Holdings

  private func holdingsSection(_ summary: CoinSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      IOSSectionTitle("Holdings")
      VStack(spacing: 0) {
        ForEach(Array(holdings.enumerated()), id: \.element.id) { index, asset in
          holdingRow(asset)
          if index < holdings.count - 1 {
            Rectangle()
              .fill(AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft)
              .frame(height: AtlasTheme.shape.hasBoldBorders ? 1.5 : 1)
              .padding(.horizontal, 14)
              .accessibilityHidden(true)
          }
        }
      }
      .iosCardSurface()
    }
  }

  private func holdingRow(_ asset: TrackedAsset) -> some View {
    HStack(spacing: 0) {
      Button {
        selectedHolding = asset
      } label: {
        HoldingRowContent(asset: asset)
          .padding(.leading, 14)
          .padding(.vertical, 8)
          .padding(.trailing, explorerURL(for: asset) == nil ? 14 : 4)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(AtlasIOSAccessibility.holding(asset))
      .accessibilityHint("Shows the full holding.")
      .accessibilityIdentifier("coin-holding-\(asset.id)")
      if let url = explorerURL(for: asset) {
        Link(destination: url) {
          Image(systemName: "arrow.up.right.square")
            .font(.body.weight(.semibold))
            .foregroundStyle(AtlasTheme.accent)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Open \(asset.symbol) address in explorer")
        .accessibilityHint("Opens in your browser.")
        .padding(.trailing, 6)
      }
    }
  }

  private func explorerURL(for asset: TrackedAsset) -> URL? {
    asset.safeExplorerURL
  }
}

// MARK: - Holding row

/// Where a holding sits and what state it is in; value and amount trailing.
struct HoldingRowContent: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var asset: TrackedAsset

  private var place: String {
    [asset.atlasNetworkLabel, asset.atlasSourceLabel].compactMap { $0 }.joined(separator: " · ")
  }

  private var kind: String { asset.atlasIOSKindLabel }

  private var unlockText: String? {
    guard asset.source == .unbonding, let date = asset.unlocksAt else { return nil }
    return "Unlocks \(date.formatted(.dateTime.day().month(.abbreviated).locale(AtlasFormatting.locale)))"
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          Text(place).font(AtlasTheme.font(.body, .body, weight: .semibold))
          Text(kind).font(AtlasTheme.font(.body, .subheadline)).foregroundStyle(AtlasTheme.ink3)
          valueText
          Text(AtlasAmount.compact(asset))
            .font(AtlasTheme.font(.number, .subheadline))
            .foregroundStyle(AtlasTheme.ink2)
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(place)
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
              .truncationMode(.tail)
            Text([kind, unlockText].compactMap { $0 }.joined(separator: " · "))
              .font(AtlasTheme.font(.body, .subheadline))
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .trailing, spacing: 3) {
            valueText
            Text(AtlasAmount.compact(asset))
              .font(AtlasTheme.font(.number, .subheadline))
              .foregroundStyle(AtlasTheme.ink2)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
          }
          .layoutPriority(1)
        }
      }
    }
    .frame(minHeight: 44)
  }

  @ViewBuilder
  private var valueText: some View {
    switch asset.pricingStatus {
    case .priced:
      Text(money(asset.valueUsd))
        .font(AtlasTheme.font(.number, .body, weight: .semibold))
        .foregroundStyle(AtlasTheme.ink)
        .lineLimit(1)
    case .unpriced:
      Text("No price")
        .font(AtlasTheme.font(.body, .subheadline, weight: .medium))
        .foregroundStyle(AtlasTheme.warning)
    case .valuationUnavailable:
      Text("Value unavailable")
        .font(AtlasTheme.font(.body, .subheadline, weight: .medium))
        .foregroundStyle(AtlasTheme.warning)
    }
  }
}

extension TrackedAsset {
  /// The stored explorer link when it is a plain web address.
  var safeExplorerURL: URL? {
    guard !explorerUrl.isEmpty, let url = URL(string: explorerUrl),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
    else { return nil }
    return url
  }
}

extension View {
  /// A coin widget in a themed card.
  func iosCoinCard() -> some View {
    IOSCard(padding: 14) { self }
  }
}
