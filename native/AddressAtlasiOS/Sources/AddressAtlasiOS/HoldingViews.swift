import AddressAtlasCore
import SwiftUI
import UIKit

// MARK: - Presentation helpers

extension TrackedAsset {
  /// Network for chain holdings; the exchange (or manual venue) otherwise.
  var atlasNetworkLabel: String {
    exchangeProvider?.label ?? chainName
  }

  /// The human name only when it adds information: native coins carry the
  /// network name as their name (`ETH` on Base is named "Base"), which the
  /// secondary line already shows.
  var atlasDisplayName: String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.caseInsensitiveCompare(symbol) != .orderedSame,
      trimmed.caseInsensitiveCompare(chainName) != .orderedSame,
      trimmed.caseInsensitiveCompare(atlasNetworkLabel) != .orderedSame
    else { return nil }
    return trimmed
  }

  var atlasIsManual: Bool { id.hasPrefix("manual-") }

  /// Wallet label (or short address) for chain holdings; the connection or
  /// manual-holding label for exchange rows.
  var atlasSourceLabel: String? {
    if family == .exchange {
      let label = (walletLabel ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
      return label.isEmpty || label == atlasNetworkLabel ? nil : label
    }
    if let walletLabel, !walletLabel.isEmpty { return walletLabel }
    return AssetsFormatting.shortAddress(address)
  }

  var atlasSecondaryLine: String {
    [atlasNetworkLabel, atlasSourceLabel].compactMap { $0 }.joined(separator: " · ")
  }

  /// Token contract (EVM, Solana mint, Tron) or XRPL issuer, recovered from
  /// the scanner's stable holding ID; nil for native coins and exchanges.
  var atlasContract: (title: String, value: String)? {
    switch source {
    case .erc20, .spl, .trc20:
      let prefix = "\(address)-\(chainId)-\(symbol)-"
      guard id.hasPrefix(prefix) else { return nil }
      let contract = String(id.dropFirst(prefix.count))
      guard !contract.isEmpty, !contract.contains(where: \.isWhitespace) else { return nil }
      return (source == .spl ? "Mint" : "Contract", contract)
    case .issued:
      guard let issuer = id.split(separator: "-").last, issuer.count > 20 else { return nil }
      return ("Issuer", String(issuer))
    default:
      return nil
    }
  }

}

enum AssetsFormatting {
  static func shortAddress(_ address: String) -> String {
    guard address.count > 14 else { return address }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }

  /// Unit prices below a dollar keep their significant digits.
  static func price(_ value: Double) -> String {
    guard value.isFinite else { return "–" }
    if value > 0, value < 1 {
      return value.formatted(
        .currency(code: "USD").precision(.significantDigits(2...6))
          .locale(AtlasFormatting.locale))
    }
    return money(value)
  }

  /// `percent` is in percentage points (2.5 = 2.5%).
  static func change24h(_ percent: Double) -> String {
    AtlasPercent.signedChange(percent / 100)
  }
}

// MARK: - Row

/// Monogram, symbol (plus name when it adds information), and network ·
/// source; value and amount trailing. At accessibility sizes the row stacks
/// vertically so nothing is pushed off screen.
struct AssetRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var asset: TrackedAsset

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        stacked
      } else {
        inline
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var inline: some View {
    HStack(spacing: 12) {
      TokenMonogram(symbol: asset.symbol, size: 40)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(asset.symbol)
            .font(AtlasTheme.font(.body, .body, weight: .semibold))
            .foregroundStyle(AtlasTheme.ink)
            .lineLimit(1)
            .layoutPriority(1)
          if let name = asset.atlasDisplayName {
            Text(name)
              .font(AtlasTheme.font(.body, .subheadline))
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
          }
        }
        // Every row has the same shape: network, then the source, which
        // truncates first (the detail sheet shows it in full).
        HStack(spacing: 0) {
          Text(asset.atlasNetworkLabel)
            .layoutPriority(1)
          if let source = asset.atlasSourceLabel {
            Text(" · \(source)")
              .truncationMode(.tail)
          }
        }
        .font(AtlasTheme.font(.body, .subheadline))
        .foregroundStyle(AtlasTheme.ink3)
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 3) {
        AssetValueText(asset: asset)
          .fixedSize()
        Text(AtlasAmount.compact(asset))
          .font(AtlasTheme.font(.number, .subheadline))
          .foregroundStyle(AtlasTheme.ink2)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .truncationMode(.middle)
      }
      .layoutPriority(1)
    }
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        TokenMonogram(symbol: asset.symbol, size: 44)
        Text(asset.symbol)
          .font(AtlasTheme.font(.body, .body, weight: .semibold))
          .foregroundStyle(AtlasTheme.ink)
          .lineLimit(2)
      }
      if let name = asset.atlasDisplayName {
        Text(name)
          .font(AtlasTheme.font(.body, .subheadline))
          .foregroundStyle(AtlasTheme.ink3)
      }
      // Money and amounts shrink instead of breaking mid-number.
      AssetValueText(asset: asset)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(AtlasAmount.compact(asset))
        .font(AtlasTheme.font(.number, .subheadline))
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(asset.atlasSecondaryLine)
        .font(AtlasTheme.font(.body, .subheadline))
        .foregroundStyle(AtlasTheme.ink3)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct AssetValueText: View {
  var asset: TrackedAsset

  var body: some View {
    switch asset.pricingStatus {
    case .priced:
      Text(money(asset.valueUsd))
        .font(AtlasTheme.font(.number, .body, weight: .semibold))
        .foregroundStyle(AtlasTheme.ink)
    case .unpriced:
      Text("Unpriced")
        .font(AtlasTheme.font(.body, .subheadline, weight: .medium))
        .foregroundStyle(AtlasTheme.warning)
    case .valuationUnavailable:
      Text("Value unavailable")
        .font(AtlasTheme.font(.body, .subheadline, weight: .medium))
        .foregroundStyle(AtlasTheme.warning)
    }
  }
}

// MARK: - Detail sheet

/// Everything stored for one holding, untruncated: value, exact amount,
/// price, network, source (wallet with its full address, or the exchange),
/// contract, and valuation status.
struct AssetDetailSheet: View {
  @Environment(\.dismiss) private var dismiss
  var asset: TrackedAsset

  var body: some View {
    NavigationStack {
      List {
        Section {
          header
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
        }

        Section("Holding") {
          AssetDetailRow(title: "Amount", value: AtlasAmount.full(asset), monospacedDigits: true)
          AssetDetailRow(title: "Price", value: priceText)
          if let change = asset.change24h, change.isFinite, asset.pricingStatus != .unpriced {
            // Below 0.005 points the value reads "0%" and stays neutral.
            AssetDetailRow(
              title: "24h change", value: AssetsFormatting.change24h(change),
              valueColor: change >= 0.005
                ? AtlasTheme.gain : (change <= -0.005 ? AtlasTheme.loss : AtlasTheme.ink))
          }
          AssetDetailRow(title: "Valuation", value: valuationText, valueColor: valuationColor)
        }
        .listRowBackground(AtlasTheme.surface)

        Section("Source") {
          AssetDetailRow(title: asset.family == .exchange ? "Venue" : "Network", value: asset.atlasNetworkLabel)
          AssetDetailRow(title: "Type", value: asset.atlasIOSKindLabel)
          sourceRows
          if let contract = asset.atlasContract {
            AssetDetailRow(title: contract.title, value: contract.value, copyable: true, stacked: true)
          }
        }
        .listRowBackground(AtlasTheme.surface)
      }
      .listStyle(.insetGrouped)
      .listSectionSpacing(.compact)
      .scrollContentBackground(.hidden)
      .background(AtlasTheme.canvas)
      .navigationTitle(asset.symbol)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .atlasDetailSheetPresentation()
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        TokenMonogram(symbol: asset.symbol, size: 52)
        VStack(alignment: .leading, spacing: 2) {
          Text(asset.symbol)
            .font(AtlasTheme.font(.display, .title3))
            .foregroundStyle(AtlasTheme.ink)
          Text(asset.atlasDisplayName ?? asset.atlasNetworkLabel)
            .font(AtlasTheme.font(.body, .subheadline))
            .foregroundStyle(AtlasTheme.ink3)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      Group {
        if asset.pricingStatus == .priced {
          Text(money(asset.valueUsd))
            .font(AtlasTheme.font(.number, .largeTitle, weight: .semibold))
            .foregroundStyle(AtlasTheme.ink)
        } else {
          Text(asset.pricingStatus == .unpriced ? "Unpriced" : "Value unavailable")
            .font(AtlasTheme.font(.display, .title))
            .foregroundStyle(AtlasTheme.warning)
        }
      }
      .lineLimit(2)
      .minimumScaleFactor(0.5)
      .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var sourceRows: some View {
    if let provider = asset.exchangeProvider {
      AssetDetailRow(title: "Exchange", value: provider.label)
      if let connection = asset.walletLabel, !connection.isEmpty {
        AssetDetailRow(title: "Connection", value: connection)
      }
    } else if asset.atlasIsManual {
      if !asset.address.isEmpty,
        asset.address.caseInsensitiveCompare(asset.atlasNetworkLabel) != .orderedSame
      {
        AssetDetailRow(title: "Label", value: asset.address)
      }
    } else {
      if let label = asset.walletLabel, !label.isEmpty {
        AssetDetailRow(title: "Wallet", value: label)
      }
      AssetDetailRow(title: "Address", value: asset.address, copyable: true, stacked: true)
    }
  }

  private var priceText: String {
    asset.pricingStatus == .unpriced ? "No price found" : AssetsFormatting.price(asset.priceUsd)
  }

  private var valuationText: String {
    switch asset.pricingStatus {
    case .priced: "Included in totals"
    case .unpriced: "Unpriced · not in totals"
    case .valuationUnavailable: "Value too large to compute · not in totals"
    }
  }

  private var valuationColor: Color {
    asset.pricingStatus == .priced ? AtlasTheme.ink : AtlasTheme.warning
  }
}

/// Label and value; values that are long identifiers sit under the label and
/// can be copied. Everything is selectable and wraps instead of truncating.
struct AssetDetailRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var title: String
  var value: String
  var valueColor: Color = AtlasTheme.ink
  var monospacedDigits = false
  var copyable = false
  var stacked = false
  @State private var copied = false

  var body: some View {
    Group {
      if stacked || dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          titleText
          HStack(alignment: .top, spacing: 8) {
            valueText
              .frame(maxWidth: .infinity, alignment: .leading)
            if copyable { copyButton }
          }
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 16) {
            titleText
            Spacer(minLength: 12)
            valueText
              .multilineTextAlignment(.trailing)
              .fixedSize()
          }
          VStack(alignment: .leading, spacing: 4) {
            titleText
            valueText
          }
        }
      }
    }
    .padding(.vertical, 4)
    .frame(minHeight: 36)
    .accessibilityElement(children: copyable ? .contain : .combine)
  }

  private var titleText: some View {
    Text(title)
      .font(AtlasTheme.font(.body, .subheadline))
      .foregroundStyle(AtlasTheme.ink3)
  }

  private var valueText: some View {
    Text(value)
      .font(monospacedDigits ? .body.monospacedDigit() : .body)
      .foregroundStyle(valueColor)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var copyButton: some View {
    Button {
      UIPasteboard.general.string = value
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .font(AtlasTheme.font(.body, .callout, weight: .semibold))
        .foregroundStyle(copied ? AtlasTheme.gain : AtlasTheme.accent)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(copied ? "Copied" : "Copy \(title.lowercased())")
  }
}
