import AddressAtlasCore
import SwiftUI

/// Individual holdings (not coins) in one card: a coin's rows on its detail
/// screen, or one snapshot's rows in History.
struct MacHoldingsTable: View {
  var holdings: [TrackedAsset]
  /// Rows from several coins name the coin; a coin's own rows do not.
  var showsSymbol: Bool

  var body: some View {
    if holdings.isEmpty {
      EmptyState(
        title: "Nothing to show", systemImage: "list.bullet",
        copy: "No holdings match.")
    } else {
      Surface(padding: 0) {
        VStack(spacing: 0) {
          ForEach(holdings) { asset in
            AssetRow(asset: asset, showsSymbol: showsSymbol)
            if asset.id != holdings.last?.id {
              Divider().overlay(AtlasTheme.ruleSoft)
            }
          }
        }
      }
    }
  }
}

/// One holding: where it is (network and wallet or exchange), its state, the
/// amount, the value, and a link to the block explorer.
struct AssetRow: View {
  @Environment(\.atlasTheme) private var tokens
  var asset: TrackedAsset
  var showsSymbol = false

  static func accessibilityIdentifier(for asset: TrackedAsset) -> String {
    "portfolio-asset-row-\(asset.id)"
  }

  private var state: HoldingState { HoldingState(asset) }

  private var explorerURL: URL? {
    guard let url = URL(string: asset.explorerUrl), url.scheme == "https", url.host() != nil
    else { return nil }
    return url
  }

  var body: some View {
    HStack(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        wide.frame(minWidth: showsSymbol ? 560 : 430)
        compact
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(AtlasAccessibility.assetRowIdentity(asset))
      .accessibilityIdentifier(Self.accessibilityIdentifier(for: asset))
      if let explorerURL {
        Link(destination: explorerURL) {
          Image(systemName: "arrow.up.right.square")
            .font(.callout)
            .foregroundStyle(tokens.color(.accent))
            .frame(width: 30, height: 30)
        }
        .help("Open in block explorer")
        .accessibilityLabel("Open \(asset.symbol) on \(asset.chainName) in the block explorer")
      } else {
        Color.clear.frame(width: 30, height: 30).accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 56)
  }

  private var wide: some View {
    HStack(spacing: 14) {
      if showsSymbol {
        HStack(spacing: 10) {
          CoinMark(symbol: asset.symbol, size: 30)
          Text(asset.symbol)
            .font(tokens.font(.body, .body, weight: .semibold))
            .foregroundStyle(tokens.color(.ink))
            .lineLimit(1)
        }
        .frame(width: 96, alignment: .leading)
      }
      whereBlock
        .frame(maxWidth: .infinity, alignment: .leading)
      stateTag
        .frame(width: 104, alignment: .leading)
      MacFigure(
        text: asset.displayedAmount(locale: AtlasFormatting.locale), size: 13,
        color: tokens.color(.ink2)
      )
      .minimumScaleFactor(0.7)
      .help(asset.canonicalAmount)
      .frame(width: 110, alignment: .trailing)
      valueText
        .frame(width: 104, alignment: .trailing)
    }
  }

  private var compact: some View {
    HStack(spacing: 12) {
      if showsSymbol { CoinMark(symbol: asset.symbol, size: 30) }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          if showsSymbol {
            Text(asset.symbol)
              .font(tokens.font(.body, .body, weight: .semibold))
              .foregroundStyle(tokens.color(.ink))
          }
          Text(MacPortfolioSnapshot.location(of: asset))
            .font(tokens.font(.body, .callout, weight: showsSymbol ? .regular : .semibold))
            .foregroundStyle(tokens.color(showsSymbol ? .ink3 : .ink))
            .lineLimit(1)
        }
        HStack(spacing: 8) {
          stateTag
          Text(sourceText)
            .font(tokens.font(.label, .caption))
            .foregroundStyle(tokens.color(.ink3))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 3) {
        valueText
        MacFigure(
          text: asset.displayedAmount(locale: AtlasFormatting.locale), size: 11,
          color: tokens.color(.ink3))
      }
    }
  }

  private var whereBlock: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(MacPortfolioSnapshot.location(of: asset))
        .font(tokens.font(.body, .body, weight: showsSymbol ? .regular : .semibold))
        .foregroundStyle(tokens.color(.ink))
        .lineLimit(1)
      Text(sourceText)
        .font(tokens.font(.label, .caption))
        .foregroundStyle(tokens.color(.ink3))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  /// The wallet's name, the exchange connection's, or the address.
  private var sourceText: String {
    let label = asset.walletLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let label, !label.isEmpty { return label }
    return asset.address
  }

  private var stateTag: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(
          CoinWidgetResolver.stateColor(state, tokens: tokens).color
        )
        .frame(width: 9, height: 9)
        .overlay {
          if tokens.shape.hasBoldBorders {
            Circle().stroke(tokens.color(.outline), lineWidth: 1.5)
          }
        }
        .accessibilityHidden(true)
      Text(state.displayName)
        .font(tokens.font(.body, .callout))
        .foregroundStyle(tokens.color(.ink2))
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private var valueText: some View {
    if asset.pricingStatus == .priced {
      MacFigure(text: money(asset.valueUsd), size: 14, weight: .semibold)
    } else {
      MacBadge(
        asset.pricingStatus == .unpriced ? "No price" : "No value",
        color: tokens.color(.warning))
    }
  }
}
